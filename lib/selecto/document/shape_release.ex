defmodule Selecto.Document.ShapeRelease do
  @moduledoc """
  Reviewed, versioned document shapes and virtual relations. All artifact keys
  are strings. Approval is an explicit authoring step and never inferred from
  sampled documents. A digest detects mutation; it is not an authorization signature.
  """
  alias Selecto.Document.{Canonical, Missing, Numeric, ObjectId, Path}

  @types ~w(string integer float boolean object array binary object_id)
  @scalar_types ~w(string integer float boolean binary object_id)
  @field_keys ~w(path type required nullable missing filterable sortable server_managed aggregate_ops scalar_array)
  @array_predicates ~w(contains contains_any contains_all)

  @spec new(map()) :: {:ok, map()} | {:error, list()}
  def new(%{"status" => "approved"}),
    do: {:error, ["approved releases cannot be redrafted in place; author a new release version"]}

  def new(input) when is_map(input) and not is_struct(input) do
    draft = input |> Map.put("status", "draft") |> Map.drop(["digest", "approval"])

    case validate(draft) do
      :ok -> {:ok, draft}
      error -> error
    end
  end

  def new(_), do: {:error, ["release must be a map"]}

  @spec approve(map(), keyword()) :: {:ok, map()} | {:error, list()}
  def approve(draft, opts \\ []) do
    reviewer = Keyword.get(opts, :approved_by)

    with :ok <- validate(draft),
         true <- draft["status"] == "draft",
         true <- is_binary(reviewer) and byte_size(reviewer) in 1..128 and String.valid?(reviewer) do
      release =
        draft
        |> Map.put("status", "approved")
        |> Map.put("approval", %{"approved_by" => reviewer})
        |> Map.delete("digest")

      {:ok, Map.put(release, "digest", Canonical.digest(release))}
    else
      false -> {:error, ["approval requires a draft and a bounded approved_by string"]}
      error -> error
    end
  end

  @spec validate(term(), keyword()) :: :ok | {:error, list()}
  def validate(release, opts \\ []) do
    errors = check_release(release, Keyword.get(opts, :require_approved, false))
    if errors == [], do: :ok, else: {:error, Enum.uniq(errors)}
  rescue
    _ -> {:error, ["malformed document release"]}
  end

  @doc "Fetch a relation with its artifact id attached."
  def relation(release, id) when is_map(release) and is_binary(id) do
    case get_in(release, ["relations", id]) do
      value when is_map(value) -> {:ok, Map.put(value, "id", id)}
      _ -> {:error, :unknown_virtual_relation}
    end
  end

  def relation(_, _), do: {:error, :unknown_virtual_relation}

  @doc "Resolve only a field published by the specified relation."
  def field(release, relation, id) when is_binary(relation) do
    with {:ok, definition} <- relation(release, relation), do: field(release, definition, id)
  end

  def field(release, %{"kind" => "root", "fields" => published}, id) do
    if is_list(published) and id in published do
      case get_in(release, ["shape", "fields", id]) do
        value when is_map(value) -> {:ok, Map.put(value, "id", id)}
        _ -> {:error, :unknown_document_field}
      end
    else
      {:error, :unpublished_document_field}
    end
  end

  def field(_release, %{"kind" => kind, "fields" => fields}, id)
      when kind in ["array", "object"] do
    case Map.fetch(fields, id) do
      {:ok, value} -> {:ok, Map.put(value, "id", id)}
      :error -> {:error, :unknown_document_field}
    end
  end

  def field(_, _, _), do: {:error, :unknown_document_field}

  @doc "Features required to preserve all refinements in an approved release, including child fields."
  def features(release) do
    fields =
      Map.values(release["shape"]["fields"]) ++
        Enum.flat_map(release["relations"], fn {_id, relation} ->
          if relation["kind"] in ["array", "object"], do: Map.values(relation["fields"]), else: []
        end)

    scalar_array =
      if Enum.any?(fields, &Map.has_key?(&1, "scalar_array")), do: ["scalar_array"], else: []

    object_relation =
      if Enum.any?(release["relations"], fn {_, rel} -> rel["kind"] == "object" end),
        do: ["object_relation"],
        else: []

    object_id = if Enum.any?(fields, &(&1["type"] == "object_id")), do: ["object_id"], else: []

    namespace =
      if Map.has_key?(release["source"], "namespace"), do: ["source_namespace"], else: []

    numeric = if Numeric.json_number?(release), do: ["json_number"], else: []

    key_access_pattern =
      if Enum.any?(release["relations"], fn {_id, relation} ->
           Enum.any?(relation["access_patterns"], fn {_name, pattern} ->
             Map.has_key?(pattern, "key_schema")
           end)
         end),
         do: ["key_access_pattern"],
         else: []

    Enum.sort(
      object_id ++ object_relation ++ scalar_array ++ namespace ++ numeric ++ key_access_pattern
    )
  end

  @doc "Validate the complete parent before returning zero or one owned object row. This helper does not authorize source access."
  def object_rows(release, relation_id, document) do
    with :ok <- validate_document(release, document),
         {:ok, %{"kind" => "object"} = relation} <- relation(release, relation_id) do
      case Path.fetch(document, relation["path"]) do
        %Missing{} -> {:ok, []}
        nil -> {:ok, []}
        object when is_map(object) and not is_struct(object) -> {:ok, [object]}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, ["an owned object relation is required"]}
    end
  end

  @doc "Validate one fetched document, including variant and identified-child semantics."
  def validate_document(release, document) do
    with :ok <- validate(release, require_approved: true) do
      errors =
        if is_map(document) and not is_struct(document) do
          validate_values(release["shape"]["fields"], document, "root", release) ++
            validate_variant(release["shape"]["variants"], document) ++
            validate_children(release, document)
        else
          ["document must be a string-keyed map"]
        end

      if errors == [], do: :ok, else: {:error, errors}
    end
  end

  @doc "Check an entire bounded scalar array; invalid arrays never match a typed membership predicate."
  def scalar_array_valid?(%{"element_type" => type, "max_elements" => maximum}, value)
      when type in ~w(string integer boolean) and is_integer(maximum) and maximum in 1..1000 and
             is_list(value) do
    bounded = Enum.take(value, maximum + 1)

    length(bounded) <= maximum and Enum.all?(bounded, &scalar_array_element?(type, &1))
  rescue
    _ -> false
  end

  def scalar_array_valid?(_, _), do: false

  @doc "Exact supported scalar-array element families; null elements and coercions are excluded."
  def scalar_array_element?("string", value),
    do: is_binary(value) and byte_size(value) <= 16_384 and String.valid?(value)

  def scalar_array_element?("integer", value),
    do: is_integer(value) and value in -9_007_199_254_740_991..9_007_199_254_740_991

  def scalar_array_element?("boolean", value), do: is_boolean(value)
  def scalar_array_element?(_, _), do: false

  defp check_release(release, require_approved) when is_map(release) and not is_struct(release) do
    source = release["source"]
    shape = release["shape"]
    relations = release["relations"]

    errors =
      check_keys(
        release,
        ~w(schema_version id status source shape relations approval digest inference_digest),
        "release"
      ) ++
        error_unless(
          is_nil(release["inference_digest"]) or digest?(release["inference_digest"]),
          "invalid inference digest"
        ) ++
        error_unless(release["schema_version"] == 1, "schema_version must be 1") ++
        error_unless(safe_release_id?(release["id"]), "invalid release id") ++
        error_unless(release["status"] in ["draft", "approved"], "invalid release status") ++
        error_unless(
          not require_approved or release["status"] == "approved",
          "release is not approved"
        ) ++
        check_source(source) ++ check_shape(shape) ++ check_relations(relations, source, shape)

    # Local checks establish bounded, parsed paths before constructing the
    # release-wide physical-path index. All relation views share one native
    # document and cannot reinterpret an atomic value's wire representation.
    errors = if errors == [], do: check_physical_paths(shape, relations), else: errors

    if errors == [] and release["status"] == "approved" do
      approval = release["approval"]

      errors ++
        error_unless(
          is_map(approval) and map_size(approval) == 1 and
            is_binary(approval["approved_by"]) and byte_size(approval["approved_by"]) in 1..128,
          "invalid approval metadata"
        ) ++
        error_unless(
          release["digest"] == Canonical.digest(Map.delete(release, "digest")),
          "release digest mismatch"
        )
    else
      errors
    end
  end

  defp check_release(_, _), do: ["release must be a string-keyed map"]

  defp check_physical_paths(shape, relations) do
    fields = Enum.map(shape["fields"], fn {_, field} -> {field["path"], field["type"]} end)

    fields =
      Enum.reduce(relations, fields, fn
        {_, %{"kind" => "array"} = relation}, fields ->
          Enum.reduce(relation["fields"], fields, fn {_, field}, fields ->
            [{relation["path"] ++ [%{"each" => true}] ++ field["path"], field["type"]} | fields]
          end)

        {_, %{"kind" => "object"} = relation}, fields ->
          Enum.reduce(relation["fields"], fields, fn {_, field}, fields ->
            [{relation["path"] ++ field["path"], field["type"]} | fields]
          end)

        _, fields ->
          fields
      end)

    object_ids =
      Enum.reduce(fields, MapSet.new(), fn
        {path, "object_id"}, paths -> MapSet.put(paths, path)
        _, paths -> paths
      end)

    conflicting_types =
      Enum.any?(fields, fn {path, type} ->
        type != "object_id" and MapSet.member?(object_ids, path)
      end)

    descendants = Enum.any?(fields, fn {path, _} -> object_id_ancestor?(path, [], object_ids) end)

    error_unless(
      not conflicting_types,
      "ObjectId physical paths cannot have conflicting field types"
    ) ++
      error_unless(
        not descendants,
        "ObjectId fields are atomic and cannot publish descendant paths"
      )
  end

  # At most 32 parsed steps are visited per field; no pairwise field scan is
  # needed. Check proper prefixes only so repeated ObjectId views stay valid.
  defp object_id_ancestor?([], _prefix, _object_ids), do: false

  defp object_id_ancestor?([step | rest], prefix, object_ids),
    do:
      MapSet.member?(object_ids, prefix) or
        object_id_ancestor?(rest, prefix ++ [step], object_ids)

  defp check_source(source) when is_map(source) and not is_struct(source) do
    check_keys(
      source,
      ~w(id kind collection sql_table identity_path tenant_path version_path namespace numeric_semantics),
      "source"
    ) ++
      error_unless(
        not Map.has_key?(source, "numeric_semantics") or
          source["numeric_semantics"] == "json_number",
        "unsupported numeric semantics"
      ) ++
      error_unless(
        not Map.has_key?(source, "namespace") or
          (is_list(source["namespace"]) and length(source["namespace"]) in 1..8 and
             Enum.all?(source["namespace"], &Path.safe_key?/1)),
        "invalid source namespace"
      ) ++
      error_unless(Path.safe_key?(source["id"]), "invalid source id") ++
      error_unless(source["kind"] == "document_collection", "unsupported source kind") ++
      error_unless(Path.safe_key?(source["collection"]), "invalid source collection") ++
      error_unless(
        is_nil(source["sql_table"]) or Path.safe_key?(source["sql_table"]),
        "invalid SQL control table"
      ) ++
      Enum.flat_map(~w(identity_path tenant_path version_path), fn key ->
        error_unless(match?({:ok, _}, Path.parse(source[key])), "invalid source #{key}")
      end) ++
      error_unless(
        length(Enum.uniq(Enum.map(~w(identity_path tenant_path version_path), &source[&1]))) == 3,
        "identity, tenant, and version paths must differ"
      )
  end

  defp check_source(_), do: ["source must be a map"]

  defp check_shape(shape) when is_map(shape) and not is_struct(shape) do
    check_keys(shape, ~w(fields variants unknown_field_policy), "shape") ++
      check_fields(shape["fields"], "shape") ++
      check_variants(shape["variants"], shape["fields"]) ++
      error_unless(
        shape["unknown_field_policy"] == "ignore",
        "V1 unknown_field_policy must be ignore"
      )
  end

  defp check_shape(_), do: ["shape must be a map"]

  defp check_fields(fields, context)
       when is_map(fields) and not is_struct(fields) and map_size(fields) in 1..256 do
    Enum.flat_map(fields, fn {id, field} ->
      error_unless(Path.safe_key?(id), "#{context}: invalid field id") ++
        check_field(field, "#{context}.#{safe_label(id)}")
    end) ++
      error_unless(
        fields
        |> Map.values()
        |> Enum.map(fn field -> if is_map(field), do: field["path"] end)
        |> Enum.uniq()
        |> length() == map_size(fields),
        "#{context}: duplicate field paths"
      )
  end

  defp check_fields(_, context), do: ["#{context}: fields must contain 1..256 entries"]

  defp check_field(field, context) when is_map(field) and not is_struct(field) do
    scalar? = field["type"] in @scalar_types

    check_keys(field, @field_keys, context) ++
      error_unless(match?({:ok, _}, Path.parse(field["path"])), "#{context}: invalid path") ++
      error_unless(field["type"] in @types, "#{context}: unsupported type") ++
      error_unless(is_boolean(field["required"]), "#{context}: required must be explicit") ++
      error_unless(is_boolean(field["nullable"]), "#{context}: nullable must be explicit") ++
      error_unless(
        field["missing"] in ["preserve", "reject"],
        "#{context}: invalid missing policy"
      ) ++
      error_unless(
        field["required"] != true or field["missing"] == "reject",
        "#{context}: required fields reject missing"
      ) ++
      Enum.flat_map(~w(filterable sortable server_managed), fn key ->
        error_unless(
          not Map.has_key?(field, key) or is_boolean(field[key]),
          "#{context}: #{key} must be boolean"
        )
      end) ++
      error_unless(
        scalar? or (field["filterable"] == false and field["sortable"] == false),
        "#{context}: opaque fields must disable filtering and sorting"
      ) ++
      check_aggregate_ops(
        field,
        if(field["type"] == "integer", do: ~w(sum min max), else: []),
        context
      ) ++ check_scalar_array(field, context)

    # Coercions, defaults, arbitrary subpaths, and executable metadata have no V1 syntax.
  end

  defp check_field(_, context), do: ["#{context}: field must be a map"]

  defp check_scalar_array(%{"scalar_array" => descriptor} = field, context)
       when is_map(descriptor) and not is_struct(descriptor) do
    operations = descriptor["predicate_ops"]

    check_keys(
      descriptor,
      ~w(element_type max_elements predicate_ops),
      context <> ".scalar_array"
    ) ++
      error_unless(field["type"] == "array", "#{context}: scalar_array requires an array field") ++
      error_unless(
        descriptor["element_type"] in ~w(string integer boolean),
        "#{context}: unsupported scalar array element type"
      ) ++
      error_unless(
        is_integer(descriptor["max_elements"]) and descriptor["max_elements"] in 1..1000,
        "#{context}: scalar array max_elements must be 1..1000"
      ) ++
      error_unless(
        is_list(operations) and length(operations) <= 3 and Enum.uniq(operations) == operations and
          Enum.all?(operations, &(&1 in @array_predicates)),
        "#{context}: scalar array predicates must be distinct supported operations"
      )
  end

  defp check_scalar_array(field, context) do
    error_unless(
      not Map.has_key?(field, "scalar_array"),
      "#{context}: scalar_array must be an explicit descriptor"
    )
  end

  defp check_variants(variants, fields) when is_map(variants) and is_map(fields) do
    values = variants["values"]

    discriminator =
      Enum.find_value(fields, fn {_, field} ->
        if is_map(field) and field["path"] == variants["path"], do: field
      end)

    check_keys(variants, ~w(path values unknown_policy), "variants") ++
      error_unless(match?({:ok, _}, Path.parse(variants["path"])), "invalid variant path") ++
      error_unless(
        is_list(values) and length(values) in 1..64 and
          Enum.all?(values, &Path.safe_key?/1) and length(Enum.uniq(values)) == length(values),
        "variants require 1..64 distinct bounded string values"
      ) ++
      error_unless(variants["unknown_policy"] == "reject", "V1 unknown variants must be rejected") ++
      error_unless(
        is_map(discriminator) and discriminator["required"] == true and
          discriminator["nullable"] == false and discriminator["type"] == "string",
        "variant discriminator must be a required non-null string field"
      )
  end

  defp check_variants(_, _),
    do: ["variants must explicitly declare path, values, and unknown_policy"]

  defp check_relations(relations, source, shape)
       when is_map(relations) and not is_struct(relations) and map_size(relations) in 1..32 and
              is_map(source) and is_map(shape) do
    roots = Enum.filter(relations, fn {_, rel} -> is_map(rel) and rel["kind"] == "root" end)

    error_unless(length(roots) == 1, "exactly one root relation is required") ++
      Enum.flat_map(relations, fn {id, rel} ->
        error_unless(Path.safe_key?(id), "invalid relation id") ++
          check_relation(rel, id, relations, source, shape)
      end) ++ check_source_fields(source, shape["fields"])
  end

  defp check_relations(_, _, _), do: ["relations require 1..32 entries and a valid source/shape"]

  defp check_relation(%{"kind" => "root"} = rel, id, _relations, source, shape) do
    fields = rel["fields"]
    shape_fields = shape["fields"]

    check_keys(
      rel,
      ~w(kind source fields identity_path access_patterns aggregate_ops),
      "relation #{safe_label(id)}"
    ) ++
      error_unless(rel["source"] == source["id"], "root source mismatch") ++
      error_unless(rel["identity_path"] == source["identity_path"], "root identity mismatch") ++
      error_unless(
        is_list(fields) and length(fields) in 1..256 and is_map(shape_fields) and
          length(Enum.uniq(fields)) == length(fields) and
          Enum.all?(fields, &Map.has_key?(shape_fields, &1)),
        "root must publish distinct declared fields"
      ) ++
      check_aggregate_ops(rel, ["count"], "root #{safe_label(id)}") ++
      check_access_patterns(rel["access_patterns"], fields)
  end

  defp check_relation(%{"kind" => "array"} = rel, id, relations, source, shape) do
    parent = relations[rel["parent"]]
    fields = rel["fields"]

    array_field =
      if is_map(shape["fields"]),
        do:
          Enum.find_value(shape["fields"], fn {_, field} ->
            if is_map(field) and field["path"] == rel["path"], do: field
          end)

    check_keys(
      rel,
      ~w(kind source parent path identity_path max_elements fields ordering duplicates access_patterns),
      "relation #{safe_label(id)}"
    ) ++
      error_unless(rel["source"] == source["id"], "child source mismatch") ++
      error_unless(is_map(parent) and parent["kind"] == "root", "child parent must be the root") ++
      error_unless(match?({:ok, _}, Path.parse(rel["path"])), "invalid child array path") ++
      error_unless(
        is_map(array_field) and array_field["type"] == "array",
        "child path must be declared as array"
      ) ++
      error_unless(
        is_integer(rel["max_elements"]) and rel["max_elements"] in 1..1000,
        "child max_elements must be 1..1000"
      ) ++
      error_unless(rel["ordering"] == "source", "child ordering must be source") ++
      error_unless(
        rel["duplicates"] == "reject_identity",
        "duplicate child identities must be rejected"
      ) ++
      check_fields(fields, "child #{safe_label(id)}") ++
      error_unless(
        is_list(rel["path"]) and is_map(fields) and
          Enum.all?(fields, fn {_, field} ->
            is_map(field) and is_list(field["path"]) and
              length(rel["path"]) + 1 + length(field["path"]) <= 32
          end),
        "combined child paths must fit the 32-step document path bound"
      ) ++
      check_identity_field(fields, rel["identity_path"], "child identity") ++
      check_access_patterns(
        rel["access_patterns"],
        if(is_map(fields) and is_map(parent),
          do: Enum.uniq(Map.keys(fields) ++ parent["fields"]),
          else: []
        )
      )
  end

  defp check_relation(%{"kind" => "object"} = rel, id, relations, source, shape) do
    parent = relations[rel["parent"]]
    fields = rel["fields"]
    shape_fields = shape["fields"]

    object_field =
      if is_map(shape_fields),
        do:
          Enum.find_value(shape_fields, fn {_, field} ->
            if is_map(field) and field["path"] == rel["path"], do: field
          end)

    check_keys(
      rel,
      ~w(kind source parent path identity cardinality fields access_patterns),
      "object relation #{safe_label(id)}"
    ) ++
      error_unless(rel["source"] == source["id"], "object source mismatch") ++
      error_unless(is_map(parent) and parent["kind"] == "root", "object parent must be the root") ++
      error_unless(match?({:ok, _}, Path.parse(rel["path"])), "invalid owned object path") ++
      error_unless(
        is_map(object_field) and object_field["type"] == "object",
        "owned object path must be declared as object"
      ) ++
      error_unless(
        rel["identity"] == "parent",
        "owned object identity must be inherited from parent"
      ) ++
      error_unless(
        rel["cardinality"] == "zero_or_one",
        "owned object cardinality must be zero_or_one"
      ) ++
      error_unless(
        is_map(shape_fields) and
          Enum.any?(shape_fields, fn {_, field} ->
            is_map(field) and field["path"] == source["identity_path"] and
              field["type"] in ["string", "object_id"]
          end),
        "owned object parent identity must be a reviewed string or object_id"
      ) ++
      check_fields(fields, "object #{safe_label(id)}") ++
      error_unless(
        is_list(rel["path"]) and is_map(fields) and
          Enum.all?(fields, fn {_, field} ->
            is_map(field) and is_list(field["path"]) and
              length(rel["path"]) + length(field["path"]) <= 32
          end),
        "combined owned object paths must fit the 32-step document path bound"
      ) ++
      check_access_patterns(rel["access_patterns"], if(is_map(parent), do: parent["fields"])) ++
      error_unless(
        is_map(parent) and is_map(parent["access_patterns"]) and is_map(rel["access_patterns"]) and
          Enum.all?(rel["access_patterns"], fn {name, pattern} ->
            parent["access_patterns"][name] == pattern
          end),
        "owned object access patterns must exactly reuse named parent index requirements"
      )
  end

  defp check_relation(_, _, _, _, _), do: ["unsupported virtual relation kind"]

  defp check_aggregate_ops(contract, supported, context) do
    operations = Map.get(contract, "aggregate_ops", [])

    error_unless(
      is_list(operations) and length(operations) <= length(supported) and
        Enum.uniq(operations) == operations and Enum.all?(operations, &(&1 in supported)),
      "#{context}: aggregate_ops must contain distinct supported operations"
    )
  end

  defp check_access_patterns(patterns, fields)
       when is_map(patterns) and not is_struct(patterns) and map_size(patterns) in 1..16 and
              is_list(fields) do
    Enum.flat_map(patterns, fn {id, pattern} ->
      if is_map(pattern) do
        expected_keys =
          if Map.has_key?(pattern, "key_schema"),
            do:
              ~w(consistent_read filter_fields index key_schema keys max_evaluated_items max_pages),
            else: ~w(index keys)

        check_keys(pattern, expected_keys, "access pattern") ++
          error_unless(
            Path.safe_key?(id) and Path.safe_key?(pattern["index"]),
            "invalid access pattern/index id"
          ) ++
          error_unless(
            is_list(pattern["keys"]) and length(pattern["keys"]) in 1..16 and
              length(Enum.uniq(pattern["keys"])) == length(pattern["keys"]) and
              Enum.all?(pattern["keys"], &(&1 in fields)),
            "access pattern keys must name distinct published fields"
          ) ++ check_key_access_pattern(pattern, fields)
      else
        ["access pattern must be a map"]
      end
    end)
  end

  defp check_access_patterns(_, _), do: ["access_patterns must declare 1..16 index requirements"]

  defp check_key_access_pattern(%{"key_schema" => schema} = pattern, fields) do
    partition = if is_map(schema), do: schema["partition"]
    sort = if is_map(schema), do: schema["sort"]

    check_keys(schema, ~w(partition sort), "key schema") ++
      error_unless(partition in fields, "partition key must name a published field") ++
      error_unless(
        is_nil(sort) or sort in fields,
        "sort key must be nil or name a published field"
      ) ++
      error_unless(
        pattern["consistent_read"] in ["strong", "eventual"],
        "consistent_read must be strong or eventual"
      ) ++
      error_unless(
        is_list(pattern["filter_fields"]) and
          length(pattern["filter_fields"]) <= 16 and
          Enum.uniq(pattern["filter_fields"]) == pattern["filter_fields"] and
          Enum.all?(pattern["filter_fields"], &(&1 in fields and &1 not in [partition, sort])),
        "filter_fields must be distinct non-key published fields"
      ) ++
      error_unless(
        is_integer(pattern["max_evaluated_items"]) and
          pattern["max_evaluated_items"] in 1..10_000,
        "max_evaluated_items must be 1..10000"
      ) ++
      error_unless(
        is_integer(pattern["max_pages"]) and pattern["max_pages"] in 1..100,
        "max_pages must be 1..100"
      )
  end

  defp check_key_access_pattern(pattern, _fields) do
    error_unless(not Map.has_key?(pattern, "key_schema"), "incomplete key access pattern")
  end

  defp check_source_fields(source, fields) when is_map(fields) do
    Enum.flat_map(~w(identity_path tenant_path version_path), fn key ->
      check_identity_field(fields, source[key], "source #{key}") ++
        error_unless(
          Enum.any?(fields, fn {_, field} ->
            is_map(field) and field["path"] == source[key] and field["server_managed"] == true
          end),
          "source #{key} must be marked server_managed"
        )
    end) ++
      error_unless(
        Enum.any?(fields, fn {_, field} ->
          is_map(field) and field["path"] == source["version_path"] and field["type"] == "integer"
        end),
        "source version field must be integer"
      ) ++
      error_unless(
        Enum.any?(fields, fn {_, field} ->
          is_map(field) and field["path"] == source["tenant_path"] and field["type"] == "string"
        end),
        "source tenant field must be string"
      )
  end

  defp check_source_fields(_, _), do: ["source metadata must resolve to shape fields"]

  defp check_identity_field(fields, path, context) when is_map(fields) do
    error_unless(
      match?({:ok, _}, Path.parse(path)) and
        Enum.any?(fields, fn {_, field} ->
          is_map(field) and field["path"] == path and field["required"] == true and
            field["nullable"] == false and field["type"] in ["string", "integer", "object_id"]
        end),
      "#{context} must resolve to a required non-null string/integer/object_id field"
    )
  end

  defp check_identity_field(_, _, context), do: ["#{context} is invalid"]

  defp validate_values(fields, document, context, release) do
    Enum.flat_map(fields, fn {id, field} ->
      value = Numeric.normalize(release, field, Path.fetch(document, field["path"]))

      cond do
        Missing.missing?(value) ->
          error_unless(field["missing"] == "preserve", "#{context}.#{id}: missing field")

        is_nil(value) ->
          error_unless(field["nullable"], "#{context}.#{id}: null is not allowed")

        true ->
          error_unless(
            Numeric.valid?(release, field, value) and type_matches?(value, field["type"]),
            "#{context}.#{id}: type mismatch"
          ) ++
            error_unless(
              not Map.has_key?(field, "scalar_array") or
                scalar_array_valid?(field["scalar_array"], value),
              "#{context}.#{id}: invalid bounded scalar array"
            )
      end
    end)
  end

  defp validate_variant(variants, document),
    do:
      error_unless(
        Path.fetch(document, variants["path"]) in variants["values"],
        "unknown document variant"
      )

  defp validate_children(release, document) do
    Enum.flat_map(release["relations"], fn
      {id, %{"kind" => "array"} = rel} ->
        case Path.fetch(document, rel["path"]) do
          %Missing{} ->
            []

          nil ->
            []

          elements when is_list(elements) ->
            # Take one over the bound so no validation traverses an unbounded array.
            bounded = Enum.take(elements, rel["max_elements"] + 1)

            if length(bounded) > rel["max_elements"] do
              ["#{id}: fan-out bound exceeded"]
            else
              identity_field =
                Enum.find_value(rel["fields"], fn {_, f} ->
                  if f["path"] == rel["identity_path"], do: f
                end)

              identities =
                Enum.map(
                  bounded,
                  &Numeric.normalize(
                    release,
                    identity_field,
                    Path.fetch(&1, rel["identity_path"])
                  )
                )

              error_unless(
                length(Enum.uniq(identities)) == length(identities),
                "#{id}: duplicate element identity"
              ) ++
                Enum.flat_map(bounded, fn element ->
                  if is_map(element) and not is_struct(element),
                    do: validate_values(rel["fields"], element, id, release),
                    else: ["#{id}: child element must be an object"]
                end)
            end

          _ ->
            ["#{id}: child path must be an array"]
        end

      {id, %{"kind" => "object"} = rel} ->
        case Path.fetch(document, rel["path"]) do
          %Missing{} ->
            []

          nil ->
            []

          value when is_map(value) and not is_struct(value) ->
            validate_values(rel["fields"], value, id, release)

          _ ->
            ["#{id}: owned child must be an object"]
        end

      _ ->
        []
    end)
  end

  defp type_matches?(v, "string"), do: is_binary(v) and String.valid?(v)
  defp type_matches?(v, "object_id"), do: ObjectId.valid?(v)
  defp type_matches?(v, "binary"), do: is_binary(v)
  defp type_matches?(v, "integer"), do: is_integer(v)
  defp type_matches?(v, "float"), do: is_float(v)
  defp type_matches?(v, "boolean"), do: is_boolean(v)
  defp type_matches?(v, "array"), do: is_list(v)
  defp type_matches?(v, "object"), do: is_map(v) and not is_struct(v)
  defp type_matches?(_, _), do: false

  defp check_keys(map, keys, context) do
    error_unless(
      Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in keys)),
      "#{context}: unknown or non-string keys"
    )
  end

  defp safe_release_id?(id) when is_binary(id) and byte_size(id) in 1..128,
    do: String.valid?(id) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_\/-]*\z/, id)

  defp safe_release_id?(_), do: false
  defp digest?(value) when is_binary(value), do: Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp digest?(_), do: false

  defp safe_label(value) when is_binary(value),
    do: binary_part(value, 0, min(64, byte_size(value)))

  defp safe_label(_), do: "invalid"
  defp error_unless(true, _), do: []
  defp error_unless(_, message), do: [message]
end
