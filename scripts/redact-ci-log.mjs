import { readFile, writeFile } from "node:fs/promises";

const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  console.error("Usage: node scripts/redact-ci-log.mjs <input> <output>");
  process.exit(2);
}

const secretNames = [
  "SUPABASE_TEST_URL",
  "SUPABASE_TEST_ANON_KEY",
  "SUPABASE_TEST_SERVICE_ROLE_KEY",
  "SUPABASE_TEST_DATABASE_URL",
];

let output = await readFile(inputPath, "utf8");
for (const name of secretNames) {
  const value = process.env[name];
  if (value) output = output.replaceAll(value, `[REDACTED:${name}]`);
}

// Also remove credentials if a client reformats the database URL before logging it.
output = output.replace(
  /postgres(?:ql)?:\/\/[^@\s]+@/gi,
  "postgresql://[REDACTED:DATABASE_CREDENTIALS]@",
);
output = output.replace(
  /\b(?:eyJ[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){1,2})\b/g,
  "[REDACTED:JWT]",
);

await writeFile(outputPath, output, { mode: 0o600 });
process.stdout.write(output);
