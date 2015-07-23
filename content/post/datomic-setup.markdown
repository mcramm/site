+++
date = "2015-07-22T20:10:00-06:00"
title = "Datomic Setup"
tags = [ "Clojure", "Datomic", "Database" ]
+++

I've recently been exploring Datomic more seriously and have found myself
jumping through the same hoops as I have in the past *just to get things up and
running*. I've also encountered slight deficiencies in the documentation that
I've had to re-investigate since the exploratory project I created was deleted
quite a while ago.

I'm tired of retracing my same steps over and over again so I thought I'd create a
quick post with some of the basic steps to get setup and using Datomic in a
Clojure application.

This is just going to cover the basics. Datomic does some crazy things I haven't
had a chance to try yet, like using [rules](http://docs.datomic.com/query.html#rules), querying the database at a [particular
instant in time](http://docs.datomic.com/tutorial.html#working-with-time), or [getting a list of changes to an entity](http://stackoverflow.com/questions/11025434/in-datomic-how-do-i-get-a-timeline-view-of-the-changes-made-to-the-values-of-a).

## Installing Datomic

You do not need to install Datomic to get started, you can use the in-memory
database.

Go here: [https://my.datomic.com/downloads/free](https://my.datomic.com/downloads/free) and find the latest version.

Then add `[com.datomic/datomic-free "<the-latest-version>"]` to your Leiningen project.


## Component Setup

This is pretty easy, but you should have something like this:

{{< highlight clojure >}}
(ns my-project.components.datomic
  (:require [com.stuartsierra.component :as component]
            [datomic.api :as datomic]))

(defrecord DatomicComponent [uri conn]
  component/Lifecycle
  (start [this]
    (if (:conn this)
      this
      (do
        (assoc this :conn (datomic/connect uri)))))
  (stop [this]
    (assoc this :conn nil)))
{{< /highlight >}}

## Schema

Schema should be ideally be kept in an EDN file and loaded on demand:

{{< highlight clojure >}}
(def schema
  (delay
    (read-string
      (slurp (io/resource "my_project/schema.edn"))))

(defn create-schema [conn]
  (datomic/transact conn @schema))
{{< /highlight >}}

Here is what your schema might look like:

{{< highlight clojure >}}
; resources/my_project/schema.edn

[
  {:db/id #db/id[:db.part/db]
   :db/ident :cake/name
   :db/valueType :db.type/string
   :db/cardinality :db.cardinality/one
   :db/fulltext true
   :db/doc "The name of a cake"
   :db.install/_attribute :db.part/db}

  {:db/id #db/id[:db.part/db]
   :db/ident :cake/owner
   :db/valueType :db.type/ref
   :db/cardinality :db.cardinality/one
   :db/doc "The owner of a cake"
   :db.install/_attribute :db.part/db}

  {:db/id #db/id[:db.part/db]
   :db/ident :user/email
   :db/unique :db.unique/value
   :db/valueType :db.type/string
   :db/cardinality :db.cardinality/one
   :db/doc "Email address of a user"
   :db.install/_attribute :db.part/db}

  {:db/id #db/id[:db.part/db]
   :db/ident :user/phone-numbers
   :db/valueType :db.type/string
   :db/cardinality :db.cardinality/many
   :db/doc "Contact numbers for a user"
   :db.install/_attribute :db.part/db}
]
{{< /highlight >}}

Information on defining your schema and all the options available
is documented [here](http://docs.datomic.com/schema.html).

## Seed Data

Like your schema, any seed data should be kept in a separate file:

{{< highlight clojure >}}
(def seed-data
  (delay
    (read-string
      (slurp (io/resource "my_project/seed.edn"))))

(defn seed-db [conn]
  (datomic/transact conn @seed-data))
{{< /highlight >}}

Here is what your seed data might look like:

{{< highlight clojure >}}
; resources/my_project/seed.edn
[
  ;; Users
  {:db/id #db/id[:db.part/user -1000001]
   :user/email "sally@test.com"
   :user/password "supersecret"
   :user/phones ["8469481047", "9471038596"]}

  {:db/id #db/id[:db.part/user -1000002]
   :user/email "bob@test.com"
   :user/password "secret"
   :user/phones ["1234567890", "0987654321"]}

  ;; Cakes
  {:db/id #db/id[:db.part/user]
   :cake/owner #db/id [:db.part/user -1000001]
   :cake/name "Carrot"}
  {:db/id #db/id[:db.part/user]
   :cake/owner #db/id [:db.part/user -1000001]
   :cake/name "Cheese"}
  {:db/id #db/id[:db.part/user]
   :cake/owner #db/id [:db.part/user -1000002]
   :cake/name "Carrot"}
]
{{< /highlight >}}

## Queries & Updates

The operations to be performed on an entity should be confined to it's own namespace:

{{< highlight clojure >}}
(ns my-project.users
  (:require [datomic.api :as datomic]
            [my-project.component.datomic])
  ; Note the change from using a dash to an underscore
  (:import [my_project.component.datomic DatomicComponent]))

(defprotocol UserOps
  (all [this])
  (by-email [this email])
  (save! [this user])

(extend-type DatomicComponent
  UserOps
  (all [this]
    (datomic/q '[:find [(pull ?user [*]) ...]
                 :where [?user :user/email]]
               (datomic/db (:conn this))))
  (by-email [this email]
    (datomic/q '[:find [(pull ?user [*])]
                 :in $ ?email
                 :where [?user :user/email ?email]]
               (datomic/db (:conn this))
               email))
  (save! [this user]
    (datomic/transact (:conn this) user)

{{< /highlight >}}

The `[(pull ?user [*]) ...]` is an example of [Datomic's pull syntax](http://docs.datomic.com/pull.html). This basically says "after all `?user`s, bring in all of their attributes. Be careful when using the wildcard `*` as this will recursively pull any component attributes.

## Traversing refs forwards and backwards

It's possible to pull in `refs` by specifying them in the pull pattern. If you wanted cakes with their owners:

{{< highlight clojure >}}
(datomic/q '[:find [(pull ?cake [* {:cake/owner [*]}]) ...]
             :where [?cake :cake/owner]]
           db)
{{< /highlight >}}

If however you wanted the reverse, users and their cakes:

{{< highlight clojure >}}
(datomic/q '[:find [(pull ?user [* {:cake/_owner [*]}]) ...]
             :where [?user :user/email]]
           db)
{{< /highlight >}}

## Recursive (graph) queries

This is one I haven't found a good real world use case for yet, but it is possible. Read the following if you're looking at doing these kinds of queries:

[http://docs.datomic.com/query.html#rules](http://docs.datomic.com/query.html#rules)

[http://hashrocket.com/blog/posts/using-datomic-as-a-graph-database](http://hashrocket.com/blog/posts/using-datomic-as-a-graph-database)
