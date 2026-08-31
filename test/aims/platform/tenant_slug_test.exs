defmodule Aims.Platform.TenantSlugTest do
  @moduledoc """
  The slug is the guard standing between user input and raw DDL, so it is
  tested adversarially rather than only for the happy path.
  """

  use ExUnit.Case, async: true

  alias Aims.Platform.TenantSlug

  describe "derive/1" do
    test "normalises an institution code into a slug" do
      assert {:ok, "c_41207"} = TenantSlug.derive("C-41207")
    end

    test "downcases and collapses runs of punctuation" do
      assert {:ok, "abc_xyz"} = TenantSlug.derive("ABC..--__XYZ")
    end

    test "trims leading and trailing separators" do
      assert {:ok, "abc"} = TenantSlug.derive("---abc---")
    end

    test "prefixes a leading digit so the slug stays a legible identifier" do
      assert {:ok, "x123"} = TenantSlug.derive("123")
    end

    test "truncates so the prefixed schema fits PostgreSQL's 63-byte limit" do
      {:ok, slug} = TenantSlug.derive(String.duplicate("a", 200))
      assert String.length(slug) <= TenantSlug.max_length()
      assert TenantSlug.valid?(slug)
      assert String.length(TenantSlug.to_schema(slug)) <= 63
    end

    test "refuses codes with nothing usable in them" do
      assert {:error, :underivable} = TenantSlug.derive("---")
      assert {:error, :underivable} = TenantSlug.derive("")
      assert {:error, :underivable} = TenantSlug.derive("!@#$%")
    end

    test "refuses non-binary input" do
      assert {:error, :underivable} = TenantSlug.derive(nil)
      assert {:error, :underivable} = TenantSlug.derive(123)
    end

    test "strips characters that would break out of an identifier" do
      {:ok, slug} = TenantSlug.derive(~s(abc"; DROP TABLE tenants; --))
      assert TenantSlug.valid?(slug)
      refute slug =~ "\""
      refute slug =~ ";"
      refute slug =~ " "
    end
  end

  describe "valid?/1" do
    test "accepts well-formed slugs" do
      assert TenantSlug.valid?("abc")
      assert TenantSlug.valid?("c_41207")
      assert TenantSlug.valid?("a1")
    end

    test "rejects an empty slug" do
      refute TenantSlug.valid?("")
    end

    test "rejects uppercase, which PostgreSQL would fold and confuse" do
      refute TenantSlug.valid?("ABC")
    end

    test "rejects every SQL metacharacter" do
      for bad <- [
            ~s(a"b),
            "a;b",
            "a b",
            "a'b",
            "a-b",
            "a.b",
            "a(b",
            "a\nb",
            "a\\b",
            "a%b"
          ] do
        refute TenantSlug.valid?(bad), "expected #{inspect(bad)} to be rejected"
      end
    end

    test "rejects slugs longer than the prefixed schema can hold" do
      refute TenantSlug.valid?(String.duplicate("a", TenantSlug.max_length() + 1))
    end

    test "rejects reserved names even though they match the grammar" do
      for reserved <- ~w(public information_schema pg_catalog pg_toast template postgres admin) do
        refute TenantSlug.valid?(reserved), "expected #{reserved} to be reserved"
      end
    end

    test "honours Triplex's own reserved list as well as ours" do
      # Belt and braces: whichever list a name appears on, it is refused.
      refute TenantSlug.valid?("www")
    end

    test "rejects non-binaries" do
      refute TenantSlug.valid?(nil)
      refute TenantSlug.valid?(:abc)
    end
  end

  describe "safe!/1" do
    test "returns a valid slug unchanged" do
      assert TenantSlug.safe!("abc") == "abc"
    end

    test "raises on anything that could escape an identifier" do
      assert_raise ArgumentError, ~r/refusing to use/, fn ->
        TenantSlug.safe!(~s(x"; DROP TABLE tenants; --))
      end
    end

    test "raises rather than returning an error tuple, because reaching it is a bug" do
      assert_raise ArgumentError, fn -> TenantSlug.safe!("public") end
      assert_raise ArgumentError, fn -> TenantSlug.safe!(nil) end
    end
  end

  describe "to_schema/1" do
    test "applies the Triplex prefix" do
      assert TenantSlug.to_schema("c_41207") == "tenant_c_41207"
    end

    test "agrees with Triplex, so the two can never drift apart" do
      assert TenantSlug.to_schema("c_41207") == Triplex.to_prefix("c_41207")
    end

    test "guards before prefixing, because the result reaches DDL" do
      assert_raise ArgumentError, fn -> TenantSlug.to_schema(~s(x"; DROP SCHEMA public; --)) end
    end
  end
end
