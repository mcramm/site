+++
date = "2016-12-14T14:33:00-06:00"
title = "Integration Testing with Clojure and Postgres"
tags = [ "Clojure", "Postgres" ]
+++

If you're writing a non-trivial application that will run in production, it's usually a good idea
to have some automated way to make sure that all the pieces are working together
correctly. On a lot of projects this is going to mean integration tests. How
granular these tests become will depend on your level of paranoia and *how*
critical those integration points are to your application as a whole.

In this post I'm going to use an example [from a previous
article](http://mcramm.com/post/off-the-ground-with-clojure-and-postgres/) and add
some integration tests to ensure that we're creating and updating accounts
correctly.

It's worth noting that my opinion on integration tests is that they should act as *smoke*
tests, except in some extreme cases. If you find yourself testing complex
business logic and needing to integrate with the database to do so, then chances
are you're doing something wrong. Integration tests should not be a replacement
for QA or to compensate for bad design. But the world isn't perfect, and sometimes
a convoluted, slow running set of integration tests is the best you can do.

Alright, enough postulating. Let's move on.  Here is the namespace that we'll be
targeting for our tests:

{{< highlight clojure >}}
(ns postgres-example.entities.accounts
  (:require [clj-time.jdbc]

            [postgres-example.sql :as sql]
            [postgres-example.components.postgres])
  (:import [postgres_example.components.postgres Postgres]))


(defprotocol AccountOps
  (by-id [this id])
  (create! [this status])
  (set-opened! [this account])
  (set-closed! [this account]))

(defn sql->account [sql-entity]
  (when (:id sql-entity)
    #:account {:id (:id sql-entity)
               :status (:status sql-entity)
               :created-at (:created_at sql-entity)
               :updated-at (:updated_at sql-entity)}))

(def opened-status "open")
(def closed-status "closed")

(extend-protocol AccountOps
  Postgres
  (by-id [store id]
    (-> (sql/account-by-id (:uri store) {:id id})
        sql->account))

  (create! [store status]
    (let [result (sql/insert-account! (:uri store) {:status status})]
      (by-id store (:id result))))

  (set-opened! [store account]
    (sql/update-account! (:uri store) {:id (:account/id account)
                                       :status opened-status})
    (by-id store (:account/id account)))

  (set-closed! [store account]
    (sql/update-account! (:uri store) {:id (:account/id account)
                                       :status closed-status})
    (by-id store (:account/id account))))
{{< /highlight >}}

This namespace's sole responsibility is to provide a touchpoint for the rest of
our app to *where* we're storing our accounts data. This is where we go when we
need to fetch or update something in our database. The reason we defined the
`AccountOps` protocol is that we may want to extend these operations over a
different store, like an AtomStore, when we move on to writing tests for other
pieces of the system.

> I think it's worth mentioning that I feel like there could be a good fit
> for [clojure.spec](http://clojure.org/about/spec) here. I'll probably explore
> this in a future post.

To start we'll need some way to actually run our tests, both from the REPL and
outside if it. For outside the REPL, we can just use `lein test`. For inside
though, we're going to add a `test` method to `dev/user.clj` that uses the
awesome [Eftest](https://github.com/weavejester/eftest) to find and run our
tests.

{{< highlight clojure >}}
; ... truncated ...
(defn test []
  (let [path "test/postgres_example/integration"]
    (eftest/run-tests (eftest/find-tests path))))
{{< /highlight >}}

Note that I had to make some other changes here as well to ensure that we have a
separate test database loaded up and migrated to the same version we're
developing against. For the full list of changes to this file, see [this
commit](https://github.com/mcramm/postgres-example/commit/0c1fbe527b442ebdbc342385cc75b0beef2171fc#diff-f83d20da641ba06134b62eab278aa907).

Let's make sure this is working with a dummy test. Create a file at
`test/postgres_example/integration/entities/accounts.clj` and add the following
content:

{{< highlight clojure >}}
(ns postgres-example.integration.entities.accounts
  (:require [clojure.test :refer :all]))

(deftest foo-test
  (testing "our setup"
    (is (= 1 2))))
{{< /highlight >}}

Running `(test)` at the REPL should display a failure. If it didn't, then you
should stop here and figure out why. If the test failed successfully,
we can move on to writing something a little more useful. We're going to write this
test *first*, then figure out some of the missing pieces in a minute.

{{< highlight clojure >}}
(ns postgres-example.integration.entities.accounts
  (:require [clojure.test :refer :all]
            [postgres-example.entities.accounts :refer :all]))

(deftest create!-test
  (testing "create! creates and returns an account"
    (let [account (create! store "open")]
      (is (not (nil? (:account/id account))))
      (is (= "open" (:account/status account))))))
{{< /highlight >}}

Pretty easy right? All we're doing with this test is ensuring that the result
of calling `create!` returns a map that has an `:account/id` set, and was assigned
the correct status. But as I said, we're missing a couple of things. First, we
haven't defined what `store` is in this context. Second, we should be cleaning up
any data we create once the test is completed.

To handle both of these problem we're going to create a `test-helpers` namespace that
our tests can reference to get a copy of the `store` (that we'll point at our
test database), and we'll create a
[fixture](https://clojuredocs.org/clojure.test/use-fixtures) that will execute some code
to clean up any test data:

{{< highlight clojure >}}
(ns postgres-example.test-helpers
  (:require [clojure.java.jdbc :as jdbc]
            [environ.core :refer [env]]
            [postgres-example.components.postgres :as postgres]))

(def ^:dynamic store nil)

(def test-db-uri (str (:database-url env) "_test"))

(defn db-transaction-fixture [f]
  (jdbc/with-db-transaction [conn test-db-uri]
    (jdbc/db-set-rollback-only! conn)
    (binding [store (postgres/build conn)]
      (f))))
{{< /highlight >}}

From the top down, we create a dynamic var for `store` that we'll re-bind to a
new connection for every test. That connection will happen to be a database
transaction that we'll instruct to rollback when it's complete, instead of
simply comitting.

> Credit to [this post by Eric
> Normand](http://www.lispcast.com/clojure-database-test-faster). Prior to this I
> had been using an `atom` instead of a dynamic var and was pulling my hair out
> trying to get my tests to run without hitting concurrency issues. Changing it to
> a dynamic var and leveraging `binding` made things quite a bit nicer. (and quite a bit faster too)

We'll need to require this namespace in our test, and tell our tests to use this
`db-transaction-fixture` fixture:

{{< highlight clojure >}}
(ns postgres-example.integration.entities.accounts
  (:require [clojure.test :refer :all]
            [postgres-example.test-helpers :refer [store db-transaction-fixture]]
            [postgres-example.entities.accounts :refer :all]))

(use-fixtures :each db-transaction-fixture)

(deftest create!-test
  (testing "create! creates and returns an account"
    (let [account (create! store "open")]
      (is (not (nil? (:account/id account))))
      (is (= "open" (:account/status account))))))
{{< /highlight >}}

Running `(test)` at the repl should be successful now. Let's fill out the rest
of our tests. I'm going to include the whole thing since it's so short:

{{< highlight clojure >}}

(ns postgres-example.integration.entities.accounts
  (:require [clojure.test :refer :all]
            [postgres-example.test-helpers :refer [store db-transaction-fixture]]
            [postgres-example.entities.accounts :refer :all]))

(use-fixtures :each db-transaction-fixture)

(deftest create!-test
  (testing "create! creates and returns an account"
    (let [account (create! store "open")]
      (is (not (nil? (:account/id account))))
      (is (= "open" (:account/status account))))))

(deftest by-id-test
  (testing "by-id returns the correct account by id"
    (let [account (create! store "open")]
      (is (= account
             (by-id store (:account/id account)))))))

(deftest set-opened!-test
  (testing "set-opened! sets an account's status to opened-status"
    (let [account (create! store "closed")]
      (set-opened! store account)
      (is (= opened-status
             (:account/status (by-id store (:account/id account))))))))

(deftest set-closed!-test
  (testing "set-closed! sets an account's status to closed-status"
    (let [account (create! store "open")]
      (set-closed! store account)
      (is (= closed-status
             (:account/status (by-id store (:account/id account))))))))
{{< /highlight >}}

These 4 tests run in about 0.022 seconds on my machine. If you check your local postgres
database, you should (hopefully) see that your accounts table is empty:

{{< highlight psql >}}
$ psql -U postgres_example postgres_example_test

postgres_example_test=# select * from accounts;
┌────┬────────┬────────────┬────────────┐
│ id │ status │ created_at │ updated_at │
├────┼────────┼────────────┼────────────┤
└────┴────────┴────────────┴────────────┘
(0 rows)

Time: 1.330 ms
{{< /highlight >}}

The `id` column is an auto-incrementing sequence though, so you should still see
that changing:

{{< highlight postgres-console >}}

postgres_example_test=# select currval('accounts_id_seq'::regclass);
┌─────────┐
│ currval │
├─────────┤
│      47 │
└─────────┘
(1 row)

Time: 1.910 ms
{{< /highlight >}}

I'll reiterate that integration tests should be used sparingly, and only in
critical places where two or more *things* are interacting together. This
pattern is the same one I apply to all Clojure projects that interact with
Postgres.

Hopefully this has been helpful to someone :). If you notice any errors in this
post, [please let me know](https://twitter.com/cramm).

