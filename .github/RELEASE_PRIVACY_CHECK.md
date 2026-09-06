# Release privacy check setup

The `Release privacy check` workflow runs the real Forecast row-level-security
suite for pull requests and every update to `main`. Configure a GitHub
Environment named `supabase-rls-test` with these protected environment secrets:

- `SUPABASE_TEST_URL`
- `SUPABASE_TEST_ANON_KEY`
- `SUPABASE_TEST_SERVICE_ROLE_KEY`
- `SUPABASE_TEST_DATABASE_URL`

All values must belong to a dedicated, disposable Supabase project. The test
applies `supabase/schema.sql`, creates temporary users and private data, and
deletes those users afterward. It must never target a development or production
project.

In the repository branch rules for `main`, require the status check named
`Live Supabase RLS (required)` before merging or releasing. Restrict the
`supabase-rls-test` Environment to the branches allowed to run release checks,
and limit who can edit its secrets.

Failed test output is redacted before it is printed or retained as an artifact.
The artifact is kept for 14 days. GitHub's own secret masking remains a second
layer of protection.
