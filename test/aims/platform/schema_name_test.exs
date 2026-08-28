defmodule Aims.Platform.SchemaNameTest do
  @moduledoc """
  `SchemaName` is the guard standing between user input and raw DDL, so it is
  tested adversarially rather than only for the happy path.
  """

  use ExUnit.Case, async: true

  alias Aims.Platform.SchemaName

  describe "derive/1" do
    test "normalises an AISHE code into a schema name" do
      assert {:ok, "tenant_c_41207"} = SchemaName.derive("C-41207")
    end

    test "downcases and collapses runs of punctuation" do
      assert {:ok, "tenant_abc_xyz"} = SchemaName.derive("ABC..--__XYZ")
    end

    test "trims leading and trailing separators" do
      assert {:ok, "tenant_abc"} = SchemaName.derive("---abc---")
    end

    test "prefixes a leading digit so the suffix stays a legible identifier" do
      assert {:ok, "tenant_x123"} = SchemaName.derive("123")
    end

    test "truncates to stay inside the 63-byte PostgreSQL identifier limit" do
      {:ok, name} = SchemaName.derive(String.duplicate("a", 200))
      assert String.length(name) <= 63
      assert SchemaName.valid?(name)
    end

    test "refuses codes with nothing usable in them" do
      assert {:error, :underivable} = SchemaName.derive("---")
      assert {:error, :underivable} = SchemaName.derive("")
      assert {:error, :underivable} = SchemaName.derive("!@#$%")
    end

    test "refuses non-binary input" do
      assert {:error, :underivable} = SchemaName.derive(nil)
      assert {:error, :underivable} = SchemaName.derive(123)
    end

    test "strips characters that would break out of an identifier" do
      {:ok, name} = SchemaName.derive(~s(abc"; DROP TABLE tenants; --))
      assert SchemaName.valid?(name)
      refute name =~ "\""
      refute name =~ ";"
      refute name =~ " "
    end
  end

  describe "valid?/1" do
    test "accepts well-formed names" do
      assert SchemaName.valid?("tenant_abc")
      assert SchemaName.valid?("tenant_c_41207")
      assert SchemaName.valid?("tenant_a1")
    end

    test "requires the tenant_ prefix" do
      refute SchemaName.valid?("abc")
      refute SchemaName.valid?("public")
      refute SchemaName.valid?("pg_catalog")
    end

    test "rejects an empty suffix" do
      refute SchemaName.valid?("tenant_")
    end

    test "rejects uppercase, which PostgreSQL would fold and confuse" do
      refute SchemaName.valid?("tenant_ABC")
    end

    test "rejects every SQL metacharacter" do
      for bad <- [
            ~s(tenant_a"b),
            "tenant_a;b",
            "tenant_a b",
            "tenant_a'b",
            "tenant_a-b",
            "tenant_a.b",
            "tenant_a(b",
            "tenant_a\nb",
            "tenant_a\\b",
            "tenant_a%b"
          ] do
        refute SchemaName.valid?(bad), "expected #{inspect(bad)} to be rejected"
      end
    end

    test "rejects names longer than PostgreSQL allows" do
      refute SchemaName.valid?("tenant_" <> String.duplicate("a", 56))
    end

    test "rejects reserved schemas even though they match the grammar" do
      refute SchemaName.valid?("tenant_public")
      refute SchemaName.valid?("tenant_pg_catalog")
      refute SchemaName.valid?("tenant_template")
    end

    test "rejects non-binaries" do
      refute SchemaName.valid?(nil)
      refute SchemaName.valid?(:tenant_abc)
    end
  end

  describe "safe!/1" do
    test "returns a valid name unchanged" do
      assert SchemaName.safe!("tenant_abc") == "tenant_abc"
    end

    test "raises on anything that could escape an identifier" do
      assert_raise ArgumentError, ~r/refusing to use/, fn ->
        SchemaName.safe!(~s(tenant_x"; DROP TABLE tenants; --))
      end
    end

    test "raises rather than returning an error tuple, because reaching it is a bug" do
      assert_raise ArgumentError, fn -> SchemaName.safe!("public") end
      assert_raise ArgumentError, fn -> SchemaName.safe!(nil) end
    end
  end
end
