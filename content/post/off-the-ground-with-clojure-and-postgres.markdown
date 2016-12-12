+++
date = "2016-12-12T20:10:00-06:00"
title = "Off the ground with Clojure and Postgres"
tags = [ "Clojure", "Postgres", "HugSQL" ]
+++

I've been writing a few apps in my spare time, most notably
[Mailfeed](https://mailfeedapp.com), and I've developed a simple pattern
whenever I need to pull data out of the database.  This pattern could be be
applied to any database you're interacting with, but in this case I'll be
showing how I *tend* to do it with Postrges.

I should say that none of this is groundbreaking stuff.  If you're an
experienced developer then you'll probably be saying "duh" a lot, but if your
playing with Clojure and are struggling to come up with a good structure on how
to do this kind of thing, then maybe this is something you could apply.

This is going to be pretty quick. Lets say you're tracking user
accounts with a status. We'd like to be able to do the following:

{{< highlight clojure >}}
(accounts/by-id store 1)
; => nil

(accounts/create! store "open")
; => #:account{:id 1,
;              :status "open",
;              :created-at "<some-instant-in-time>",
;              :updated-at "<some-instant-in-time>"}

(accounts/set-closed! store (accounts/by-id store 1))
; => #:account{:id 1,
;              :status "closed",
;              :created-at "<some-instant-in-time>",
;              :updated-at "<some-instant-in-time>"}
{{< /highlight >}}

Note that the resulting representation of accounts and invoices is a namespaced map, which is new to Clojure 1.9.
It's exactly the same as:

{{< highlight clojure >}}
{:account/id 1
 :account/status "closed"
 :account/created-at "<some-instant-in-time>"
 :account/updated-at "<some-instant-in-time>"}
{{< /highlight >}}

Let's tackle this top-down by defining a protocol for the operations we're performing.

{{< highlight clojure >}}
(ns my-project.entities.accounts)

(defprotocol AccountOps
  (by-id [this id])
  (create! [this status])
  (set-opened! [this account])
  (set-closed! [this account]))
{{< /highlight >}}

Okay that was easy, but what the heck is `this` going to be in the context of the final implementations of
these methods? At this point it doesn't *really* matter. We could define a new record called `AtomStore` and
extend our protocol over it, but that isn't the point of this post. I'll leave that as an exercise for the
reader.

We're going to jump right in and create a `Postgres` component that will be passed a connection string to a
running postgres instance, with a database already created. [I have a full example here](https://github.com/mcramm/postgres-example) that
also sets up [Ragtime](https://github.com/weavejester/ragtime) to ensure the necessary schema exists.

{{< highlight clojure >}}
(ns my-project.components.postgres)

(defrecord Postgres [uri])

(defn build [uri]
  (->Postgres uri))
{{< /highlight >}}


At this point we could switch back to our accounts namespace and extend the AccountOps protocol over it, but
we still need some way of actually querying our database. For that we're going to use [HugSQL](http://www.hugsql.org) which will
will let us define our queries in raw sql.

Let's start with writing a query to look up an account by an id. Open a new file at `resources/sql/accounts.sql`
and add the following content:
{{< highlight sql >}}
-- :name account-by-id :? :1
-- :doc Get an account by id
SELECT *
FROM accounts
WHERE id = :id
{{< /highlight >}}

HugSQL will parse this file and define a new function called `account-by-id` in whatever namespace we load it
in. The `:?` marks it as a query and the `:1` will cause it to only return 1
result.

Now we'll create a namespace to define this function in:

{{< highlight clojure >}}
(ns my-project.sql
  (:require [hugsql.core :as hugsql]))

(hugsql/def-db-fns "sql/accounts.sql")
{{< /highlight >}}

After loading this namespace, we'll then have a function we can call to load an account by an id:

{{< highlight clojure >}}
(require '[my-project.sql :as sql])
(sql/account-by-id "your-database-uri" {:id 123})
; => nil
{{< /highlight >}}

Hurray! It worked... kinda. Let's define a way to create a new account with an
initial status:

{{< highlight sql >}}
-- :name insert-account! :<! :1
-- :doc Inserts an account and returns the id
INSERT INTO accounts (status)
VALUES (:status)
RETURNING id
{{< /highlight >}}

You'll have to reload your REPL if you're following along at one. This will define a new method called
`insert-account!` and return the id of the row that was just inserted. Now you can do the following:
{{< highlight clojure >}}
(require '[my-project.sql :as sql])
(sql/insert-account! "your-database-uri" {:status "open"})
; => {:id 1}
(sql/account-by-id "your-database-uri" {:id 1})
; => {:id 1, :status "open", :created_at #inst "2016-12-12T00:00:00.000000000-00:00", :updated_at #inst "2016-12-12T00:00:00.000000000-00:00"}
{{< /highlight >}}

> Your database uri should look something like
> `postgresql://postgres_example:secret@localhost:5432/postgres_example`,
> assuming you've created a user `postgres_example` with the password `secret`,
> and a dabaase with the same name. This dosen't *have* to be a connection
> string, but it's the most straightforward way of specifying the connection
> details that I've encountered so far.

Switch back to our accounts namespace and use these functions in our AccountOps protocol:

{{< highlight clojure >}}
(ns my-project.entities.accounts
  (:require [my-project.components.postgres]
            [my-project.sql :as sql])
  (:import [my_project.components.postgres Postgres]))

(defprotocol AccountOps
  (by-id [this id])
  (create! [this status])
  (set-opened! [this account])
  (set-closed! [this account]))

(extend-protocol AccountOps
  Postgres
  (by-id [this id]
    (sql/account-by-id (:db-spec this) {:id id}))

  (create! [this status]
    (let [result (sql/insert-account! (:db-spec this) {:status status})]
      (by-id this (:id result)))))
{{< /highlight >}}

Note that I haven't implemented the `set-closed!` or `set-opened!` protocols
yet. We'll get to them in a minute.

Because this example is a little contrived, the solution here seems almost
too straightforward. The only interesting piece is that `create!`
passes it's result immediately to `by-id` for re-fetching. This is a design
decision I'm making; your needs may vary.

We're missing something though. Remember our example at the beginning of this article returned us a namespaced
map, but we're getting back just a regular one. To do this we're going to pass
every result of `sql/account-by-id` through a function `sql->account`:

{{< highlight clojure >}}
(ns my-project.entities.accounts
  (:require [my-project.components.postgres]
            [my-project.sql :as sql])
  (:import [my_project.components.postgres Postgres]))

(defprotocol AccountOps
  (by-id [this id])
  (create! [this status])
  (set-opened! [this account])
  (set-closed! [this account]))

(defn sql->account [sql-entity]
  (when (:id sql-entity)
    #:account{:id         (:id sql-entity)
              :status     (:status sql-entity)
              :created-at (:created_at sql-entity)
              :updated-at (:updated_at sql-entity)}))

(extend-protocol AccountOps
  Postgres
  (by-id [this id]
    (-> (sql/account-by-id (:db-spec this) {:id id})
        sql->account))

  (create! [this status]
    (let [result (sql/insert-account! (:db-spec this) {:status status})]
      (by-id this (:id result)))))
{{< /highlight >}}

It's usually a good idea to insulate your code from outside dependencies like
the database. Here we're taking the raw result returned to us from HugSQL and
mapping it to our own internal representation of it. This also gives us a place
to manipulate the data to suite our needs as it comes out of the database.

There is one more thing I would recommend doing at this point, and it would be
to require `clj-time.jdbc` in our accounts namespace:

{{< highlight clojure >}}
(ns my-project.entities.accounts
  (:require [clj-time.jdbc]

            [my-project.components.postgres]
            [my-project.sql :as sql])
  (:import [my_project.components.postgres Postgres]))
{{< /highlight >}}

The [clj-time](https://github.com/clj-time/clj-time) library is great on it's
own, and including this namespace will ensure that as the JDBC library pulls
dates out of the database, that they're mapped to JodaTime instances.

Now we're finally ready to give these a try:

{{< highlight clojure >}}
(accounts/by-id store 1)
; => nil

(accounts/create! store "open")
; => #:account{:id 1,
;              :status "open",
;              :created-at #object[org.joda.time.DateTime 0x17dffb5 "2016-12-12T00:00:00.000Z"],
;              :updated-at #object[org.joda.time.DateTime 0x7e0ac645 "2016-12-12T00:00:00.000Z"]}

(accounts/by-id store 1)
; => #:account{:id 1,
;              :status "open",
;              :created-at #object[org.joda.time.DateTime 0x17dffb5 "2016-12-12T00:00:00.000Z"],
;              :updated-at #object[org.joda.time.DateTime 0x7e0ac645 "2016-12-12T00:00:00.000Z"]}
{{< /highlight >}}

Success! The last thing we'll do is implement our `set-*` functions.

{{< highlight clojure >}}

;; ========================================
;; in my-project.entities.accounts

(def opened-status "open")
(def closed-status "closed")

(extend-protocol AccountOps
  Postgres
  ;; ... truncated ...
  (set-closed! [store account]
    (sql/update-account! (:uri store) {:id (:account/id account)
                                       :status closed-status})
    (by-id store (:account/id account))))
  (set-open! [store account]
    (sql/update-account! (:uri store) {:id (:account/id account)
                                       :status opened-status})
    (by-id store (:account/id account))))
{{< /highlight >}}

{{< highlight sql >}}

-- ========================================
-- in resources/sql/accounts.sql

-- :name update-account! :< :1
-- :doc Updates an account by id
UPDATE accounts
SET status = :status,
    updated_at = now()
WHERE id = :id
RETURNING id

{{< /highlight >}}

And let's try them out:

{{< highlight clojure >}}

(def my-account (accounts/by-id store 1))

(:account/status my-account)
; => "open"

(accounts/set-closed! store my-account)
; => #:account{:id 1,
;              :status "closed",
;              :created-at #object[org.joda.time.DateTime 0x17dffb5 "2016-12-12T00:00:00.000Z"],
;              :updated-at #object[org.joda.time.DateTime 0x7e0ac645 "2016-12-12T00:00:00.000Z"]}

;; Note that `my-account` hasen't changed
(:account/status my-account)
; => "open"

(accounts/set-opened! store my-account)
; => #:account{:id 1,
;              :status "open",
;              :created-at #object[org.joda.time.DateTime 0x17dffb5 "2016-12-12T00:00:00.000Z"],
;              :updated-at #object[org.joda.time.DateTime 0x7e0ac645 "2016-12-12T00:00:00.000Z"]}
{{< /highlight >}}

And bam! That's it.

As I said before, this example is a little small and contrived, but I've found
it to be a good jumping off point for most projects to start with.

If you notice any errors in this post, [please let me know](https://twitter.com/cramm).
