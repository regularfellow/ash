defmodule Ash.Query.Aggregate do
  @moduledoc "Represents an aggregated association value"
  defstruct [
    :name,
    :relationship_path,
    :default_value,
    :query,
    :kind,
    :type,
    :authorization_filter
  ]

  @type t :: %__MODULE__{}

  alias Ash.Actions.SideLoad
  alias Ash.Engine.Request

  def new(_resource, name, kind, relationship, query) do
    with {:ok, type} <- kind_to_type(kind),
         {:ok, query} <- validate_query(query) do
      {:ok,
       %__MODULE__{
         name: name,
         default_value: default_value(kind),
         relationship_path: List.wrap(relationship),
         kind: kind,
         type: type,
         query: query
       }}
    end
  end

  defp default_value(:count), do: 0

  defp validate_query(query) do
    cond do
      query.side_load != [] ->
        {:error, "Cannot side load in an aggregate"}

      query.aggregates != %{} ->
        {:error, "Cannot aggregate in an aggregate"}

      query.sort != [] ->
        {:error, "Cannot sort an aggregate (for now)"}

      not is_nil(query.limit) ->
        {:error, "Cannot limit an aggregate (for now)"}

      not (is_nil(query.offset) || query.offset == 0) ->
        {:error, "Cannot offset an aggregate (for now)"}

      true ->
        {:ok, query}
    end
  end

  defp kind_to_type(:count), do: {:ok, Ash.Type.Integer}
  defp kind_to_type(kind), do: {:error, "Invalid aggregate kind: #{kind}"}

  def requests(initial_query, authorizing?) do
    initial_query.aggregates
    |> Map.values()
    |> Enum.group_by(& &1.relationship_path)
    |> Enum.reduce({[], [], []}, fn {relationship_path, aggregates},
                                    {auth_requests, value_requests, aggregates_in_query} ->
      related = Ash.Resource.related(initial_query.resource, relationship_path)

      relationship =
        Ash.Resource.relationship(
          initial_query.resource,
          List.first(relationship_path)
        )

      remaining_path = List.delete_at(relationship_path, 0)

      {in_query?, reverse_relationship} =
        case SideLoad.reverse_relationship_path(relationship, remaining_path) do
          :error ->
            {true, nil}

          {:ok, reverse_relationship} ->
            {any_aggregate_matching_path_used_in_query?(initial_query, relationship_path),
             reverse_relationship}
        end

      auth_request =
        if authorizing? do
          Request.new(
            resource: related,
            api: initial_query.api,
            async?: false,
            query: aggregate_query(related, reverse_relationship),
            path: [:aggregate, relationship_path],
            strict_check_only?: true,
            action: Ash.Resource.primary_action!(related, :read),
            name: "authorize aggregate: #{Enum.join(relationship_path, ".")}",
            data: []
          )
        else
          nil
        end

      new_auth_requests =
        if auth_request do
          [auth_request | auth_requests]
        else
          auth_requests
        end

      if in_query? do
        {new_auth_requests, value_requests, aggregates_in_query ++ aggregates}
      else
        request =
          value_request(
            initial_query,
            related,
            reverse_relationship,
            relationship_path,
            aggregates,
            auth_request
          )

        {new_auth_requests, [request | value_requests], aggregates_in_query}
      end
    end)
  end

  defp value_request(
         initial_query,
         related,
         reverse_relationship,
         relationship_path,
         aggregates,
         auth_request
       ) do
    pkey = Ash.Resource.primary_key(initial_query.resource)

    deps =
      if auth_request do
        [auth_request.path ++ [:authorization_filter], [:data, :data]]
      else
        [[:data, :data]]
      end

    Request.new(
      resource: initial_query.resource,
      api: initial_query.api,
      query: aggregate_query(related, reverse_relationship),
      path: [:aggregate_values, relationship_path],
      action: Ash.Resource.primary_action!(initial_query.resource, :read),
      name: "fetch aggregate: #{Enum.join(relationship_path, ".")}",
      data:
        Request.resolve(
          deps,
          fn data ->
            if data.data.data == [] do
              {:ok, %{}}
            else
              initial_query = Ash.Query.unset(initial_query, [:filter, :sort, :aggregates])

              query =
                case data.data.data do
                  [record] ->
                    Ash.Query.filter(
                      initial_query,
                      record |> Map.take(pkey) |> Enum.to_list()
                    )

                  records ->
                    Ash.Query.filter(initial_query,
                      or: [Enum.map(records, &Map.take(&1, pkey))]
                    )
                end

              aggregates =
                if auth_request do
                  case get_in(data, [auth_request.path ++ [:authorization_filter]]) do
                    nil ->
                      aggregates

                    filter ->
                      Enum.map(aggregates, fn aggregate ->
                        %{aggregate | query: Ash.Query.filter(aggregate.query, filter)}
                      end)
                  end
                else
                  aggregates
                end

              with {:ok, data_layer_query} <-
                     add_datalayer_aggregates(query.data_layer_query, aggregates, query.resource),
                   {:ok, results} <-
                     Ash.DataLayer.run_query(
                       data_layer_query,
                       query.resource
                     ) do
                aggregate_values =
                  Enum.reduce(results, %{}, fn result, acc ->
                    Map.put(
                      acc,
                      Map.take(result, pkey),
                      Map.take(result.aggregates || %{}, Enum.map(aggregates, & &1.name))
                    )
                  end)

                {:ok, aggregate_values}
              else
                {:error, error} ->
                  {:error, error}
              end
            end
          end
        )
    )
  end

  defp add_datalayer_aggregates(data_layer_query, aggregates, resource) do
    Enum.reduce_while(aggregates, {:ok, data_layer_query}, fn aggregate,
                                                              {:ok, data_layer_query} ->
      case Ash.DataLayer.add_aggregate(
             data_layer_query,
             aggregate,
             resource
           ) do
        {:ok, data_layer_query} -> {:cont, {:ok, data_layer_query}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp aggregate_query(resource, reverse_relationship) do
    Request.resolve(
      [[:data, :query]],
      fn data ->
        data_query = data.data.query

        filter = Ash.Filter.put_at_path(data_query.filter, reverse_relationship)

        {:ok, Ash.Query.filter(resource, filter)}
      end
    )
  end

  defp any_aggregate_matching_path_used_in_query?(query, relationship_path) do
    filter_aggregates =
      if query.filter do
        Ash.Filter.used_aggregates(query.filter)
      else
        []
      end

    if Enum.any?(filter_aggregates, &(&1.relationship_path == relationship_path)) do
      true
    else
      sort_aggregates =
        Enum.flat_map(query.sort, fn {field, _} ->
          case Map.fetch(query.aggregates, field) do
            :error ->
              []

            {:ok, agg} ->
              [agg]
          end
        end)

      Enum.any?(sort_aggregates, &(&1.relationship_path == relationship_path))
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%{query: nil} = aggregate, opts) do
      container_doc(
        "#" <> to_string(aggregate.kind) <> "<",
        [Enum.join(aggregate.relationship_path, ".")],
        ">",
        opts,
        fn str, _ -> str end,
        separator: ""
      )
    end

    def inspect(%{query: query} = aggregate, opts) do
      container_doc(
        "#" <> to_string(aggregate.kind) <> "<",
        [
          concat([
            Enum.join(aggregate.relationship_path, "."),
            concat(" from ", to_doc(query, opts))
          ])
        ],
        ">",
        opts,
        fn str, _ -> str end
      )
    end
  end
end