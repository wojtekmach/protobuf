defmodule Protobuf.Protoc.Generator.Message do
  @moduledoc false
  alias Protobuf.Protoc.Generator.Util
  alias Protobuf.TypeUtil
  alias Protobuf.Protoc.Generator.Enum, as: EnumGenerator

  def generate_list(ctx, descs) do
    descs
    |> Enum.map(fn desc -> generate(ctx, desc) end)
    |> Enum.unzip()
  end

  def generate(ctx, desc) do
    msg_struct = parse_desc(ctx, desc)
    ctx = %{ctx | namespace: msg_struct[:new_namespace]}
    {nested_enums, nested_msgs} = Enum.unzip(gen_nested_msgs(ctx, desc))

    {gen_nested_enums(ctx, desc) ++ nested_enums,
     nested_msgs ++ [gen_msg(ctx.syntax, msg_struct)]}
  end

  def parse_desc(%{namespace: ns} = ctx, desc) do
    new_ns = ns ++ [Util.trans_name(desc.name)]
    fields = get_fields(ctx, desc)
    extensions = get_extensions(desc)
    generate_desc = if ctx.gen_descriptors?, do: desc, else: nil

    %{
      new_namespace: new_ns,
      name: Util.mod_name(ctx, new_ns),
      options: msg_opts_str(ctx, desc.options),
      structs: structs_str(desc, extensions),
      typespec: typespec_str(fields, desc.oneof_decl, extensions),
      fields: fields,
      oneofs: oneofs_str(desc.oneof_decl),
      desc: generate_desc,
      transform_module: ctx.transform_module,
      extensions: extensions
    }
  end

  defp gen_msg(syntax, msg_struct) do
    Protobuf.Protoc.Template.message(
      msg_struct[:name],
      msg_struct[:options],
      msg_struct[:structs],
      msg_struct[:typespec],
      msg_struct[:oneofs],
      gen_fields(syntax, msg_struct[:fields]),
      msg_struct[:desc],
      msg_struct[:transform_module],
      gen_extensions(msg_struct[:extensions])
    )
  end

  defp gen_nested_msgs(ctx, desc) do
    Enum.map(desc.nested_type, fn msg_desc -> generate(ctx, msg_desc) end)
  end

  defp gen_nested_enums(ctx, desc) do
    Enum.map(desc.enum_type, fn enum_desc -> EnumGenerator.generate(ctx, enum_desc) end)
  end

  defp gen_fields(syntax, fields) do
    Enum.map(fields, fn %{opts_str: opts_str} = f ->
      label_str =
        if syntax == :proto3 && f[:label] != "repeated", do: "", else: "#{f[:label]}: true, "

      ":#{f[:name]}, #{f[:number]}, #{label_str}type: #{f[:type]}#{opts_str}"
    end)
  end

  defp gen_extensions([]) do
    nil
  end

  defp gen_extensions(exts) do
    inspect(exts, limit: :infinity)
  end

  def msg_opts_str(%{syntax: syntax}, opts) do
    msg_options = opts

    opts = %{
      syntax: syntax,
      map: msg_options && msg_options.map_entry,
      deprecated: msg_options && msg_options.deprecated
    }

    str = Util.options_to_str(opts)
    if String.length(str) > 0, do: ", " <> str, else: ""
  end

  def structs_str(struct, extensions) do
    fields = Enum.filter(struct.field, fn f -> !f.oneof_index end)

    fields =
      if Enum.empty?(extensions) do
        fields
      else
        fields ++ [%{name: :__pb_extensions__}]
      end

    Enum.map_join(struct.oneof_decl ++ fields, ", ", fn f -> ":#{f.name}" end)
  end

  def typespec_str([], [], []), do: "  @type t :: %__MODULE__{}\n"
  def typespec_str([], [], [_ | _]), do: "  @type t :: %__MODULE__{__pb_extensions__: map}\n"

  def typespec_str(fields, oneofs, extensions) do
    longest_width = fields |> Enum.map(&String.length(&1.name)) |> Enum.max()

    {oneof_fields, regular_fields} = Enum.split_with(fields, & &1[:oneof])

    oneof_types = oneof_types(oneofs, oneof_fields, longest_width)
    regular_types = regular_types(regular_fields, longest_width)
    extensions_types = extensions_types(extensions, longest_width)

    types = oneof_types ++ regular_types ++ extensions_types

    "  @type t :: %__MODULE__{\n" <>
      Enum.map_join(types, ",\n", fn {k, v} ->
        "    #{k} #{v}"
      end) <> "\n  }\n"
  end

  defp oneof_types(oneofs, oneof_fields, longest_width) do
    oneofs
    |> Enum.with_index()
    |> Enum.map(fn {oneof, index} ->
      typespec =
        oneof_fields
        |> Enum.filter(&(&1.oneof == index))
        |> Enum.map_join(" | ", &"{:#{&1.name}, #{fmt_type(&1)}}")

      {fmt_type_name(oneof.name, longest_width), typespec}
    end)
  end

  defp regular_types(fields, longest_width) do
    for f <- fields, do: {fmt_type_name(f.name, longest_width), fmt_type(f)}
  end

  defp extensions_types(_extensions = [], _longest_width), do: []

  defp extensions_types(_extensions, longest_width) do
    [{fmt_type_name(:__pb_extensions__, longest_width), "map"}]
  end

  defp oneofs_str(oneofs) do
    oneofs
    |> Enum.with_index()
    |> Enum.map(fn {oneof, index} ->
      "oneof :#{oneof.name}, #{index}"
    end)
  end

  defp fmt_type_name(name, len) do
    String.pad_trailing("#{name}:", len + 1)
  end

  defp fmt_type(%{opts: %{map: true}, map: {{k_type_enum, _k_type}, {v_type_enum, v_type}}}) do
    # Keys are guaranteed to be scalars. Values can be anything except another map. Map fields
    # cannot be `repeated`.
    k_spec = TypeUtil.enum_to_spec(k_type_enum)
    v_spec = type_to_spec(v_type_enum, v_type)
    v_spec = optional_if_message(v_type_enum, v_spec)

    "%{#{k_spec} => #{v_spec}}"
  end

  defp fmt_type(%{label: label, type_enum: type_enum, type: type}) do
    spec = type_to_spec(type_enum, type)

    if label == "repeated" do
      "[#{spec}]"
    else
      optional_if_message(type_enum, spec)
    end
  end

  defp type_to_spec(:TYPE_MESSAGE, type), do: "#{type}.t()"
  defp type_to_spec(:TYPE_ENUM, type), do: "#{type}.t()"
  defp type_to_spec(type_scalar, _type), do: TypeUtil.enum_to_spec(type_scalar)

  defp optional_if_message(:TYPE_MESSAGE, spec), do: "#{spec} | nil"
  defp optional_if_message(_type_others, spec), do: spec

  def get_fields(ctx, desc) do
    oneofs = Enum.map(desc.oneof_decl, & &1.name)
    nested_maps = nested_maps(ctx, desc)
    Enum.map(desc.field, fn f -> get_field(ctx, f, nested_maps, oneofs) end)
  end

  def get_field(ctx, f, nested_maps, oneofs) do
    opts = field_options(f, ctx.syntax)
    map = nested_maps[f.type_name]
    opts = if map, do: Map.put(opts, :map, true), else: opts

    opts =
      if length(oneofs) > 0 && f.oneof_index, do: Map.put(opts, :oneof, f.oneof_index), else: opts

    opts_str = Util.options_to_str(opts)
    opts_str = if opts_str == "", do: "", else: ", " <> opts_str

    type = field_type_name(ctx, f)

    %{
      name: f.name,
      number: f.number,
      label: label_name(f.label),
      type: type,
      type_enum: f.type,
      opts: opts,
      opts_str: opts_str,
      map: map,
      oneof: f.oneof_index
    }
  end

  defp get_extensions(desc) do
    Enum.map(desc.extension_range, fn range ->
      {range.start, range.end}
    end)
  end

  defp field_type_name(ctx, f) do
    type = TypeUtil.from_enum(f.type)

    if f.type_name && (type == :enum || type == :message) do
      Util.type_from_type_name(ctx, f.type_name)
    else
      ":#{type}"
    end
  end

  # Map of protobuf are actually nested(one level) messages
  defp nested_maps(ctx, desc) do
    full_name = Util.join_name([ctx.package | ctx.namespace] ++ [desc.name])
    prefix = "." <> full_name

    Enum.reduce(desc.nested_type, %{}, fn desc, acc ->
      if desc.options && desc.options.map_entry do
        [k, v] = Enum.sort(desc.field, &(&1.number < &2.number))

        pair = {{k.type, field_type_name(ctx, k)}, {v.type, field_type_name(ctx, v)}}

        Map.put(acc, Util.join_name([prefix, desc.name]), pair)
      else
        acc
      end
    end)
  end

  defp field_options(f, syntax) do
    enum? = f.type == :TYPE_ENUM
    default = default_value(f.type, f.default_value)

    %{enum: enum?, default: default}
    |> put_json_name(syntax, f)
    |> merge_field_options(f)
  end

  defp label_name(:LABEL_OPTIONAL), do: "optional"
  defp label_name(:LABEL_REQUIRED), do: "required"
  defp label_name(:LABEL_REPEATED), do: "repeated"

  defp default_value(_, ""), do: nil
  defp default_value(_, nil), do: nil

  defp default_value(t, val) do
    v = do_default_value(t, val)
    if v == nil, do: v, else: inspect(v)
  end

  defp do_default_value(:TYPE_DOUBLE, v), do: float_default(v)
  defp do_default_value(:TYPE_FLOAT, v), do: float_default(v)
  defp do_default_value(:TYPE_INT64, v), do: int_default(v)
  defp do_default_value(:TYPE_UINT64, v), do: int_default(v)
  defp do_default_value(:TYPE_INT32, v), do: int_default(v)
  defp do_default_value(:TYPE_FIXED64, v), do: int_default(v)
  defp do_default_value(:TYPE_FIXED32, v), do: int_default(v)
  defp do_default_value(:TYPE_BOOL, v), do: String.to_atom(v)
  defp do_default_value(:TYPE_STRING, v), do: v
  defp do_default_value(:TYPE_BYTES, v), do: v
  defp do_default_value(:TYPE_UINT32, v), do: int_default(v)
  defp do_default_value(:TYPE_ENUM, v), do: String.to_atom(v)
  defp do_default_value(:TYPE_SFIXED32, v), do: int_default(v)
  defp do_default_value(:TYPE_SFIXED64, v), do: int_default(v)
  defp do_default_value(:TYPE_SINT32, v), do: int_default(v)
  defp do_default_value(:TYPE_SINT64, v), do: int_default(v)
  defp do_default_value(_, _), do: nil

  defp float_default(value) do
    case Float.parse(value) do
      {v, _} -> v
      :error -> value
    end
  end

  defp int_default(value) do
    case Integer.parse(value) do
      {v, _} -> v
      :error -> value
    end
  end

  defp merge_field_options(opts, %{options: nil}), do: opts

  defp merge_field_options(opts, f) do
    opts
    |> Map.put(:packed, f.options.packed)
    |> Map.put(:deprecated, f.options.deprecated)
  end

  # Omit `json_name` from the options list when it matches the original field
  # name to keep the list small. Only Proto3 has JSON support for now.
  defp put_json_name(opts, :proto3, %{name: name, json_name: name}), do: opts

  defp put_json_name(opts, :proto3, %{json_name: json_name}) do
    Map.put(opts, :json_name, inspect(json_name))
  end

  defp put_json_name(opts, _syntax, _props), do: opts
end
