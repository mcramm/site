+++
date = "2017-04-15T13:21:00-07:00"
title = "Mailfeed In Retrospect"
tags = [ "Clojure", "Mailfeed" ]
+++

It's been a few weeks since I [announced on /r/Clojure](https://www.reddit.com/r/Clojure/comments/60lqvw/my_first_clojure_production_app_mailfeed) I was finished working on Mailfeed, a service that emails you whenever an RSS feed updates. A comment on that thread suggested that I share a little about the technologies I used and some of the pitfalls I hit during development.

There's a lot to talk about, so I thought I'd just drop a nice big list of all the major tech, services and libraries, then move on to some of the more interesting challenges.

Major Tech used:

* Clojure(script)
* Postgres
* Nginx

Services:

* Stathat
* Rollbar
* Papertrail
* Mailgun
* Digital Ocean

Libraries:

* Ring
* Compojure
* Enlive (for emails)
* Hiccup (for everything else)
* HugSQL
* Ragtime
* Environ
* Quartzite
* Buddy
* Component
* clj-time
* clj-stripe
* clj-http
* clj-rollcage

The meat of the application is in the worker and the web apps. Both of these are
written entirely in Clojure with a _little_ Clojurescript on one page in the
web app. I chose Postgres as a database simply because I already knew it really
 well.

## RSS Processing Woes

The first iteration of Mailfeed was basically the same app that exists
today with the worker existing as a background thread that was spun up whenever
the app booted. I designed the system using
[Component](https://github.com/stuartsierra/component) early on, and
although I had a couple of small trip-ups along the way, I'm very glad that I
chose it.

At that time the worker was very un-optimized, generated a lot
of errors, and died from time to time. Rebooting it meant rebooting the whole
application and this made the engineer in me cry. The worker is the *core* of the application; it does a lot of heavy lifting and is the main reason anyone would ever want to
actually use the service.

In my first spike I tried to convert the worker to using
[core.async](https://github.com/clojure/core.async), but it started to feel like the wrong solution pretty quick. The library is more about communication
between two processes and what I wanted was a completely independent process that
would:

1. Query the database at a regular interval
2. Get any feeds that needed to be updated
3. Process new entries for these feeds
4. Send any relevant emails to subscribers.

On my next spike I sat down and wrote a "Scheduler" component in [Quartzite](http://clojurequartz.info), abstracting the task of feed refreshing into it's own job. I peppered in some error handling to ensure that **when** an error occurred, the job could clean up and continue. I made sure to fire the error off to [Rollbar](https://rollbar.com) as I still wanted visibility on them.

Everything worked but the process was still really slow. At the time I had around 30 feeds that I wanted to refresh every 5 minutes. On average, the job was completing in about 40 seconds with an occasional spike up into 2 minutes. This was *technically* still within my acceptable time frame, but still felt a little extreme for such a small number of feeds. I added in some monitoring, sending the processing times of a few different functions to [StatHat](http://stathat.com), and left it for a few days to get a good baseline. I blocked off my next weekend to investigate and see what improvements could be made.

When I sat down on Saturday morning I poked around and determined the job was spending most of its time waiting for a response from a few different sites. Everything else was pretty speedy. Since network latency was completely outside of my ability to correct, I decided to look at parallelizing the feed fetching/processing task. I went back to core.async very briefly again, before remembering about [pmap](https://clojuredocs.org/clojure.core/pmap). I made the switch from:

{{< highlight clojure >}}
(dorun (map update-feed (get-feeds)))
{{< /highlight >}}

To:

{{< highlight clojure >}}
(dorun (pmap update-feed (get-feeds)))
{{< /highlight >}}


After a lot more testing to make sure I hadn't missed anything, I found that I had brought the average total processing time for the job down to 2 seconds.

 Woo hoo!

I decided to call that "mission accomplished" and closed my computer to go make breakfast. Even now with almost 3 times the number of feeds, the mean time for the job to complete is 3.113 seconds.

## The Monolith with Two Doors

At this point I was really happy with how the worker was performing, but still felt like it made sense to completely separate the worker from the web app in production. I wanted them to be able to exist on their own boxes so that I could fine tune each individually.

I mentioned previously that I was using component to try and keep the logical
pieces of Mailfeed as separate as possible. With Component you create "systems"
which is basically just a way of describing all your components and the
components they depend on to do their job. What I had was two systems
that shared a lot of the same components, but whose primary functions were
quite different.

So that's what I created. The "Web System" contained the all the routes, the
web handler, the database and the mailer, while the "Worker System" contained
the scheduler, the database, the mailer and the feed parser. When I go to
deploy, I build two JARs in [Boot](http://boot-clj.com):

{{< highlight clojure >}}
(deftask build-web []
 (comp (aot :namespace '#{mailfeed.web.core})
  (pom)
  (uber)
  (jar :main 'mailfeed.web.core
       :file "mailfeed-web.jar")
  (target :dir #{"target/web"})))

(deftask build-worker []
 (comp (aot :namespace '#{mailfeed.worker.core})
  (pom)
  (uber)
  (jar :main 'mailfeed.worker.core
       :file "mailfeed-worker.jar")
  (target :dir #{"target/worker"})))
{{< /highlight >}}

Overall I'm actually really happy with this approach. The only thing I have to
be careful of is database migrations. If I make a change for one part of the
application, I need to make sure everything is backwards compatible, since there
is no mechanism for keeping both the worker and the web app in-sync. I do one
deploy, and then the other. This is mostly-OK, since it's generally a good idea
to write a migration to *add* a new thing, then, if you need to, write another
migration to *remove* the old thing once you've verified it's not being used
anymore.

This leads me into my next topic; one that I'm not very excited to share:

# Deployment

Right now Mailfeed is deployed to [Digital Ocean](https://www.digitalocean.com/). Everything is deployed with a couple of shell scripts and some preconfigured
"droplets" that I set up by hand then took snapshots of.

The above sentence should have made you go:

<img
style="width: 30em"
src="https://cloud.githubusercontent.com/assets/150988/24832190/5f719e88-1c67-11e7-8d44-e3ddec4b3dba.jpg" />

Yeah... I'm right there with you. Dumb! Dumb. Baaad Mike.

But it works! I ran a failure-scenario a couple of months ago and I managed to
get everything up and running again within 30 minutes. That's not ... great, but
considering how mission-critical the application is, it's not bad either.
And if I had paying customers then I would spend the time to rework everything
through Ansible.

If I was starting again today, then Ansible would definitely be technology I would consider to provision these servers for me. I've used in the past and had very a very good experience with it. Daniel Higginbotham has also recently released a book "[Deploying Your First Clojure App ...From the Shadows](https://gum.co/gHcWk)"
that I *wish* had existed before I started Mailfeed.

# Monitoring

I've written a bit about monitoring, but in summary I:

* Track of errors with Rollbar
* Send some key stats with Stathat
* Monitor hardware with Digital Ocean Monitoring
* Logs with Papertrail

I experimented a bit with Riemann early on but found it was a little over my head at the time. It certainly seems capable of tracking most of the above, without the limitations imposed by having to stick to the Free account tiers.

# What's the lesson?

I was really happy with using Clojure and I didn't have any huge surprises during development. But every story should have a lesson! I think the big lessons I learned weren't really related to the actual development process, but more to the things that need to go along around it. If I had to pick something I needed to improve it would be to do a little more up front market research and planning instead of just jumping in and building something I and a few friends of mine wanted.

Hopefully some of that was insightful. If you're reading this and are curious about something specific, please don't hesitate to reach out on [Twitter](https://twitter.com/cramm).
