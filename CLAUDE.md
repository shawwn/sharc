Don't `(declare 'atstrings nil)`. Instead, escape @ symbols inside strings by doubling (e.g. `"foo@bar.com"` becomes `"foo@@bar.com"`.)

Instead of `(foo 'bar)`, use `!` syntax (i.e. `foo!bar`).

Note that an `!` after a close paren like `(load-config)!username` is incorrect syntax; use `((load-config) 'username)` in those cases.

Bracket-lambda gotcha: `[_!dead]` expands to `(fn (_) (_!dead))` = `(fn (_) ((_ 'dead)))` which calls the result. Need `[_ 'dead]`.

Instead of:

```
(let user (fetch-user id)
  (when user
    ...))
```

you can use arc's `whenlet`:

```
(whenlet user (fetch-user id)
  ...)
```

Use + to join lists together. E.g. `(+ '(a b c) '(d e f))` gives `(a b c d e f)`

Don't strip informative comments or docstrings when refactoring code unless explicitly asked to.

Don't delete files under `arc/`. e.g. `arc/news/story/1`

`(is x y)` does a deep compare of x and y. For object identity, use `(ex x y)`. (`ex` is short for `exactly`.)

You can't use ! after a closing paren, like `((newstories maxend*) 2)!id`.

A `(t var)` param defaults to a thread-local: `(t var)` => `(o var (the var))`, and `(t local var)` => `(o local (the var))`.
E.g. `(def ip ((t req)) req!ip)` makes `(ip)` use `(the req)` while `(ip some-req)` uses the arg. See `examples/the.arc`.

`is` is isomorphic, e.g. `(is (list 'a) (list 'a))` returns `t`. `iso` exists for backwards compatibility.
If you need to compare object identity, use `ex`, e.g. `(ex (list 'a) (list 'a))` returns `nil`.

You can call CL macros e.g. like this: `(#'sb-ext::with-timeout ...)`
