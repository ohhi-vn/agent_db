defmodule AgentDb.Store.NodesProjectionTest do
  @moduledoc """
  The projection a search statement builds from a caller's field selection.

  The column list is the one place a caller-supplied value is interpolated into
  SQL, so it is the one place an injection could enter. Everything here is about
  that being impossible by construction: a name is a key into a fixed map, and a
  name that is not a key produces an error rather than a statement.
  """
  use ExUnit.Case, async: true

  alias AgentDb.Store.Nodes

  # Every column this module's own table has, which is the whole set a
  # projection may ever name.
  @node_columns ~w(uri content abstract overview enabled group_tag)

  describe "projection_columns/1" do
    test "keeps only the selected data columns" do
      assert {:ok, [:uri, :abstract, :enabled, :group_tag]} =
               Nodes.projection_columns([:uri, :abstract])
    end

    test "always reads the URI" do
      assert {:ok, columns} = Nodes.projection_columns([:abstract])
      assert :uri in columns
    end

    test "always reads the internal pair, so the caller can still filter" do
      assert {:ok, columns} = Nodes.projection_columns([:uri])
      assert :enabled in columns
      assert :group_tag in columns
    end

    test "ignores a repeated name rather than reading a column twice" do
      assert {:ok, columns} = Nodes.projection_columns([:uri, :uri, :abstract])
      assert columns == Enum.uniq(columns)
    end
  end

  describe "projection_sql/1" do
    test "maps every column to a fixed fragment" do
      for column <- Enum.map(@node_columns, &String.to_atom/1) do
        assert {:ok, _sql} = Nodes.projection_sql([column])
      end
    end

    test "produces only column names, whatever the caller selected" do
      # The statement is built by joining these, so the join is where an
      # injected name would have to survive.
      assert {:ok, columns} = Nodes.projection_columns([:uri, :abstract, :overview])
      assert {:ok, sql} = Nodes.projection_sql(columns)

      assert String.split(sql, ", ") -- @node_columns == []
    end

    test "a name that is not a column is refused, with no statement built" do
      # This is the guard. A field name never reaches SQL as text, so there is
      # no way to write a statement out of one.
      assert {:error, {:unknown_projection_column, :injected}} =
               Nodes.projection_sql([:uri, :injected])

      assert {:error, {:unknown_projection_column, :"uri, 1; DROP TABLE nodes"}} =
               Nodes.projection_sql([:uri, :"uri, 1; DROP TABLE nodes"])
    end

    test "keeps the column order the row mapper reads back" do
      # One order is shared by the statement and the mapper, so a rename or a
      # new column cannot put the two out of step.
      assert {:ok, columns} = Nodes.projection_columns([:uri, :content, :overview])
      assert {:ok, sql} = Nodes.projection_sql(columns)

      assert String.split(sql, ", ") == Enum.map(columns, &Atom.to_string/1)
    end
  end
end
