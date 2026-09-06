import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { test } from "node:test";

const requiredEnvironment = [
  "SUPABASE_TEST_URL",
  "SUPABASE_TEST_ANON_KEY",
  "SUPABASE_TEST_SERVICE_ROLE_KEY",
  "SUPABASE_TEST_DATABASE_URL",
] as const;

const missingEnvironment = requiredEnvironment.filter(
  (name) => !process.env[name],
);
if (process.env.SUPABASE_RLS_REQUIRED === "true" && missingEnvironment.length) {
  throw new Error(
    `Live Supabase RLS checks are required, but these CI secrets are unavailable: ${missingEnvironment.join(", ")}`,
  );
}
const skipReason = missingEnvironment.length
  ? `Set ${missingEnvironment.join(", ")} to run the disposable Supabase RLS test`
  : false;

type AuthUser = { id: string; email: string; accessToken: string };
type Group = { id: string; inviteCode: string };

function runPsql(databaseUrl: string, sql: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn("psql", [databaseUrl, "--set", "ON_ERROR_STOP=1", "--no-psqlrc"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stderr = "";
    child.stderr.setEncoding("utf8").on("data", (chunk) => { stderr += chunk; });
    child.stdout.resume();
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`Applying supabase/schema.sql failed (${code}): ${stderr.trim()}`));
    });
    child.stdin.end(sql);
  });
}

async function supabaseRequest<T>(
  baseUrl: string,
  apiKey: string,
  path: string,
  init: RequestInit = {},
  accessToken = apiKey,
): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      apikey: apiKey,
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
      ...init.headers,
    },
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${init.method ?? "GET"} ${path} failed (${response.status}): ${text}`);
  }
  return (text ? JSON.parse(text) : null) as T;
}

async function createUser(
  baseUrl: string,
  anonKey: string,
  serviceRoleKey: string,
  email: string,
  password: string,
  name: string,
  onCreated: (id: string) => void,
): Promise<AuthUser> {
  const created = await supabaseRequest<{ id: string }>(
    baseUrl,
    serviceRoleKey,
    "/auth/v1/admin/users",
    {
      method: "POST",
      body: JSON.stringify({
        email,
        password,
        email_confirm: true,
        user_metadata: { name },
      }),
    },
  );
  onCreated(created.id);
  const session = await supabaseRequest<{ access_token: string }>(
    baseUrl,
    anonKey,
    "/auth/v1/token?grant_type=password",
    { method: "POST", body: JSON.stringify({ email, password }) },
  );
  await supabaseRequest(
    baseUrl,
    anonKey,
    "/rest/v1/forecast_profiles",
    {
      method: "POST",
      headers: { prefer: "return=minimal" },
      body: JSON.stringify({ id: created.id, email, name }),
    },
    session.access_token,
  );
  return { id: created.id, email, accessToken: session.access_token };
}

async function createGroup(baseUrl: string, anonKey: string, user: AuthUser, name: string): Promise<Group> {
  return supabaseRequest<Group>(
    baseUrl,
    anonKey,
    "/rest/v1/rpc/forecast_create_group",
    {
      method: "POST",
      body: JSON.stringify({ p_name: name, p_description: "Disposable RLS integration test" }),
    },
    user.accessToken,
  );
}

async function directRows(
  baseUrl: string,
  anonKey: string,
  user: AuthUser,
  table: string,
  query: string,
): Promise<Array<Record<string, unknown>>> {
  return supabaseRequest(
    baseUrl,
    anonKey,
    `/rest/v1/${table}?select=*&${query}`,
    {},
    user.accessToken,
  );
}

test("real Supabase RLS isolates private market data between non-members", { skip: skipReason }, async () => {
  const baseUrl = process.env.SUPABASE_TEST_URL!.replace(/\/$/, "");
  const anonKey = process.env.SUPABASE_TEST_ANON_KEY!;
  const serviceRoleKey = process.env.SUPABASE_TEST_SERVICE_ROLE_KEY!;
  const databaseUrl = process.env.SUPABASE_TEST_DATABASE_URL!;
  const suffix = `${Date.now()}-${process.pid}`;
  const password = `Rls-${suffix}-aA1!`;
  const createdUserIds: string[] = [];

  const schema = await readFile(new URL("../../../supabase/schema.sql", import.meta.url), "utf8");
  await runPsql(databaseUrl, schema);

  try {
    const first = await createUser(
      baseUrl, anonKey, serviceRoleKey, `forecast-rls-a-${suffix}@example.invalid`, password, "RLS User A",
      (id) => createdUserIds.push(id),
    );
    const second = await createUser(
      baseUrl, anonKey, serviceRoleKey, `forecast-rls-b-${suffix}@example.invalid`, password, "RLS User B",
      (id) => createdUserIds.push(id),
    );

    const firstGroup = await createGroup(baseUrl, anonKey, first, `Private A ${suffix}`);
    const secondGroup = await createGroup(baseUrl, anonKey, second, `Private B ${suffix}`);

    // Exercise the real join function without making either user a member of the other's group.
    await supabaseRequest(baseUrl, anonKey, "/rest/v1/rpc/forecast_join_group", {
      method: "POST",
      body: JSON.stringify({ p_invite_code: firstGroup.inviteCode }),
    }, first.accessToken);
    await supabaseRequest(baseUrl, anonKey, "/rest/v1/rpc/forecast_join_group", {
      method: "POST",
      body: JSON.stringify({ p_invite_code: secondGroup.inviteCode }),
    }, second.accessToken);

    const firstMarket = await supabaseRequest<{ id: string }[]>(
      baseUrl,
      anonKey,
      "/rest/v1/forecast_markets",
      {
        method: "POST",
        headers: { prefer: "return=representation" },
        body: JSON.stringify({
          group_id: firstGroup.id,
          creator_id: first.id,
          question: "Can user B see user A's market?",
          description: "This row must remain private.",
          category: "security",
          closes_at: "2099-01-01T00:00:00.000Z",
        }),
      },
      first.accessToken,
    );
    assert.ok(firstMarket[0]?.id);

    const position = await supabaseRequest<{ id: string }>(
      baseUrl,
      anonKey,
      "/rest/v1/rpc/forecast_place_position",
      {
        method: "POST",
        body: JSON.stringify({ p_market_id: firstMarket[0].id, p_side: "yes", p_amount: 25 }),
      },
      first.accessToken,
    );
    assert.ok(position.id);

    assert.equal((await directRows(baseUrl, anonKey, first, "forecast_groups", `id=eq.${firstGroup.id}`)).length, 1);
    assert.equal((await directRows(baseUrl, anonKey, first, "forecast_markets", `id=eq.${firstMarket[0].id}`)).length, 1);
    assert.equal((await directRows(baseUrl, anonKey, first, "forecast_positions", `id=eq.${position.id}`)).length, 1);
    assert.equal((await directRows(baseUrl, anonKey, first, "forecast_activity", `market_id=eq.${firstMarket[0].id}`)).length, 1);

    assert.deepEqual(await directRows(baseUrl, anonKey, second, "forecast_groups", `id=eq.${firstGroup.id}`), []);
    assert.deepEqual(await directRows(baseUrl, anonKey, second, "forecast_markets", `id=eq.${firstMarket[0].id}`), []);
    assert.deepEqual(await directRows(baseUrl, anonKey, second, "forecast_positions", `id=eq.${position.id}`), []);
    assert.deepEqual(await directRows(baseUrl, anonKey, second, "forecast_activity", `market_id=eq.${firstMarket[0].id}`), []);

    assert.deepEqual(await directRows(baseUrl, anonKey, first, "forecast_groups", `id=eq.${secondGroup.id}`), []);
  } finally {
    await Promise.all(createdUserIds.map((id) =>
      supabaseRequest(baseUrl, serviceRoleKey, `/auth/v1/admin/users/${id}`, { method: "DELETE" }),
    ));
  }
});