# Governed document actions

Document actions support an identified-part reservation and bounded root scalar
patches. Both require one document identity, trusted tenant
scope, an expected version, and an idempotency key. An approved ShapeRelease
publishes the source and paths. Explicit Domain write/action policy grants
authority; approval and inference do not grant writes.

`SelectoUpdato.DocumentActionExample.domain/1` is the independently authored
synthetic policy paired with `Selecto.Document.Fixtures.release/0`. It keeps
`writes.operations.update` enabled and scalar assignment of identity, tenant,
version, and parts disabled. The array field explicitly lists `reserve_part`
in `writes.fields.parts.document_actions`.

```elixir
domain = SelectoUpdato.DocumentActionExample.domain()

{:ok, plan} = SelectoUpdato.plan_domain_action(domain, %{
  action: :reserve_part,
  target: %{id: "wo-1"},
  inputs: %{
    part_id: "part-1",
    quantity: 2,
    expected_version: 1,
    idempotency_key: "reserve-request-1"
  }
})

SelectoUpdato.ActionExecutionAdapter.execute(
  MyHostActionAdapter,
  plan,
  %{tenant_id: "tenant-a", actor: current_actor},
  capability_resolver: MyCapabilityResolver
)
```

The host adapter receives the ordinary authorized action plan and forwards its
operation builder to `SelectoUpdato.execute/3` with its configured `%Selecto{}`
and the unchanged authorization context. Use `dry_run/4` and
`SelectoUpdato.preview/3` for a preview. A caller cannot execute the opaque plan
handle or modify the sealed action. Missing or denied capability decisions
fail before dispatch.

The resulting `Selecto.Write.Command` remains an `:update`. Its
`metadata.document` contains `%Selecto.Write.DocumentMutation{}` with parsed
paths, the trusted tenant, target, expected version, release id/digest,
idempotency key/payload digest, and named effects. Core derives required
document capabilities from this structure even if callers omit them. The
adapter must atomically enforce the complete predicate, exactly one element
identity, non-null integer semantics, version increment, and durable receipt
and effect records. There is no application-side read-modify-write fallback.

The reference profile accepts one array element increment of 1 through 100.
Missing/null/non-integer fields, duplicate element identities, protected paths,
native expressions, positional indices, drafts, scalar assignment alongside
mutations, and weakened cardinality are rejected. The separate root patch
profile below does not mix with an element increment. Create, delete, replace,
upsert, and multi-document transactions remain unsupported.

`Selecto.Write.DocumentReceipt.new/2` provides stable receipt/effect identities,
matched/modified counts, the resulting version, release evidence, and adapter
evidence. Persistence and idempotency replay belong to the adapter. A repeated
key with changed payload must fail; a valid replay returns its stored receipt.
Durable effect records describe publication intent and do not guarantee
external delivery. The existing committed-effect sink capability must remain
unavailable for adapters that cannot execute it transactionally.

The Updato tests cover planning, authorization, scoping and preflight against a
recording adapter. Core exercises a finite path/amount matrix and receipt
identity behavior. These checks do not prove live database atomicity,
concurrency, or external delivery; the adapter's live tests establish those
specific database fixture boundaries separately.


Approved releases with typed scalar-array fields add `shape_features: ["scalar_array"]`
to the portable mutation. Core derives `:document_scalar_array` from that data,
so adapters that do not enforce the refinement fail before dispatch. MongoDB
checks feature metadata against the exact host-approved release and applies
the typed-array shape guards inside the existing atomic update filter. This
does not enable new mutation operations. Feature-free releases retain their
original persisted idempotency payload encoding.

Owned one-to-one object relations likewise add `"object_relation"` to the
release's shape features and require `:document_object_relation`. The requirement
applies even when an action updates a different, already-approved array relation:
the adapter must still enforce the whole document's object-field rules. Typed
scalar arrays inside an owned object require both capabilities. These refinements
do not authorize object mutation or add a new write operation.

For ObjectId identities, use the explicit
`SelectoUpdato.DocumentActionExample.object_id_domain/1` variant. Its source
identity and `part_id` input declare `:object_id`; the approved release must
publish the corresponding root and child identity fields as `"object_id"`.
Updato accepts only the canonical portable value, for example:

```elixir
{:ok, target_id} = Selecto.Document.ObjectId.new("507f1f77bcf86cd799439011")
{:ok, part_id} = Selecto.Document.ObjectId.new("507f1f77bcf86cd799439012")
# Each value is exactly %{"$bson" => "object_id", "value" => 24_lowercase_hex_digits}.
```

Pass `target: %{id: target_id}` and `inputs: %{part_id: part_id, ...}` through
the same planner and host authorization boundary shown above. Raw strings,
vendor structs, malformed tags, uppercase tagged hex, and maps with extra keys
are rejected. A string field containing the same 24 hexadecimal characters
remains a string. Declaring an input type cannot override the release's identity
type. Tenant context remains the existing trusted string/integer scope.

The full approved release adds `"object_id"` to mutation shape features and
requires `:document_object_id` before dispatch, alongside other shape features.
Canonical tags remain unchanged in portable predicates, mutation selectors,
receipt targets, and effects; only the database adapter performs native codec
conversion. Typed identities have distinct scope/idempotency hashes from string
lookalikes. The original `domain/1` fixture and feature-free idempotency encoding
remain unchanged. Updato tests cover this boundary with a recording adapter;
native ObjectId storage, comparison, and concurrency require the adapter's live
tests.

## Root scalar patches and selected postimages

`SelectoUpdato.DocumentActionExample.patch_domain/1` provides the authored
`revise_work_order` action for `Selecto.Document.Fixtures.patch_release/0`:

```elixir
{:ok, plan} = SelectoUpdato.plan_domain_action(
  SelectoUpdato.DocumentActionExample.patch_domain(),
  %{
    action: :revise_work_order,
    target: %{id: Selecto.Document.Fixtures.object_id(1)},
    inputs: %{title: "Reviewed title", priority: 3, expedited: true,
              expected_version: 1, idempotency_key: "revise-request-1"}
  }
)
```

Execute or preview this plan through the same authorized host boundary. Its
`execution.document.mutations` contains 1–8 authored entries such as
`%{op: :set, field: :title, value_from: :title}` or
`%{op: :unset, field: :due_at}`. Each field must be a published root scalar and
explicitly grant the named action in `writes.fields.<id>.document_actions`.
Ordinary scalar assignment permission does not grant document mutation. Updato
resolves field IDs to the approved parsed paths; callers cannot supply paths or
native expressions. Identity, tenant, version, receipt storage, discriminator,
arrays, and server-managed root or owned-object paths are protected, including
their ancestors and descendants.

After action input coercion, set values must match the published type: valid
UTF-8 strings up to 16,384 bytes, integers within the portable 53-bit range,
booleans, canonical ObjectIds, or explicitly nullable null. The combined set
values are bounded at 65,536 bytes. Unset requires an optional field with
`missing: "preserve"`. Duplicate or overlapping paths and mixed root/element
mutations fail before dispatch. The adapter enforces existing object parents
and validates the complete original and candidate documents atomically.

Authored `execution.returning` is `:none` or 1–16 distinct published root scalar
field IDs in the requested order; `:all`, empty lists, child fields and opaque
objects/arrays are rejected. Selection and order are bound into the idempotency
payload. Required capabilities follow the actual operations: `:document_set`,
`:document_unset`, and, for selected fields, `:document_postimage` and update
returning support, alongside all release feature capabilities.

The adapter persists the selected postimage in the receipt using exact portable
cells: `%{"field" => "due_at", "present" => false}` for missing, or
`%{"field" => "due_at", "present" => true, "value" => nil}` for null. Its normal
result row decodes missing cells to `Selecto.Document.Missing`; ObjectIds remain
canonical tags. The shared postimage codec enforces the conservative 16,384-byte
budget. An idempotent replay must return the original stored postimage even
after later writes. Updato transports the adapter's normalized result; its
recording-adapter tests prove planning, policy, preflight and result transport.
Atomic persistence, postimage validation, races and replay remain the concrete
adapter's live verification responsibilities.
