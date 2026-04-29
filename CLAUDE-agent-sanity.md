# Agent A — {{ROLE_A}} [{{FEATURE}}]

You are the **Sanity agent** for this co-located Sanity+Next.js project.
Your counterpart is the **Next.js agent** working simultaneously in `{{DIR_B}}`.

Both worktrees come from the same git repo — you each have an isolated branch
so there are no filesystem conflicts.

---

## Your ownership

| What you own | Path |
|---|---|
| Schema definitions | `{{DIR_A}}/sanity/schemas/` |
| GROQ query strings | `{{DIR_A}}/sanity/lib/queries/` |
| Sanity config | `{{DIR_A}}/sanity.config.ts` |
| Generated types | `{{DIR_A}}/sanity.types.ts` |
| Schema JSON | `{{DIR_A}}/schema.json` |

**Do not edit** `/app/`, `/components/`, `/lib/`, `next.config.ts` — those belong
to the Next.js agent. You may read them freely.

---

## After every schema change: run typegen

When you add or modify any file in `{{DIR_A}}/sanity/schemas/`, regenerate types immediately:

```bash
echo "running" > {{BRIDGE}}/typegen-status

cd {{DIR_A}}
npx sanity typegen generate 2>&1 | tee {{BRIDGE}}/typegen-log.md

echo "done" > {{BRIDGE}}/typegen-status
```

Then notify the Next.js agent so they know `sanity.types.ts` is current.

---

## Adding a new module schema

When you add a new Sanity module (e.g. Hero), the full workflow is:

1. Create `{{DIR_A}}/sanity/schemas/modules/hero.ts`
2. Register it in `{{DIR_A}}/sanity/schemas/index.ts`
3. Add a GROQ projection to `{{DIR_A}}/sanity/lib/queries/modules.ts`
4. Run typegen (see above)
5. Update the schema contract:

```bash
cat >> {{BRIDGE}}/schema-contract.md << 'EOF'

## Module: hero

Type: `HeroModule`

Fields:
- `_type: "hero"`
- `_key: string`
- `heading: string`
- `subheading?: string`
- `image?: SanityImageType`

GROQ location: {{DIR_A}}/sanity/lib/queries/modules.ts
EOF
```

6. Queue the registry work:

```bash
echo "hero|HeroModule" >> {{BRIDGE}}/module-registry-queue.md
```

7. Notify the Next.js agent:

```bash
{{BRIDGE}}/send-to-agent.sh b "New module: hero. Typegen done. Need: components/modules/templates/Hero.tsx + module-registry.ts entry. See {{BRIDGE}}/schema-contract.md for type shape."
```

---

## Maintaining the schema contract

After adding or changing queries in `{{DIR_A}}/sanity/lib/queries/`, document
the return shape in `{{BRIDGE}}/schema-contract.md`. The Next.js agent reads
this before writing fetch functions.

Format: one section per query with field names and types.

---

## Bridge: `{{BRIDGE}}`

```bash
# Send a message to the Next.js agent
{{BRIDGE}}/send-to-agent.sh b "Your message"

# Read a response from the Next.js agent
cat {{BRIDGE}}/b-to-a.md

# Check Next.js agent status
cat {{BRIDGE}}/b-status   # idle | pending | working

# View full conversation log
cat {{BRIDGE}}/conversation-log.md
```

---

## Reading the Next.js side directly

```bash
# See what fetch functions exist
ls {{DIR_B}}/lib/sanity/queries/

# Check how a type is used in components
grep -r "PagePayload\|PostPayload" {{DIR_B}}/components/

# See the module registry
cat {{DIR_B}}/components/modules/module-registry.ts
```

---

## Dev server

One `npm run dev` runs both Next.js and the embedded Studio:

```bash
cd {{DIR_A}} && npm run dev
# Next.js:  http://localhost:3000
# Studio:   http://localhost:3000/studio
```

---

## Your priorities for this session

Feature: **{{FEATURE}}**

1. Schema is the source of truth — design before writing GROQ
2. Always run typegen after schema changes, before notifying the Next.js agent
3. Keep `{{BRIDGE}}/schema-contract.md` current — the Next.js agent depends on it
4. When adding a module, the workflow isn't complete until the Next.js agent confirms registration
