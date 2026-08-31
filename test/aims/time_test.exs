defmodule Aims.TimeTest do
  @moduledoc """
  The rule under test: storage is UTC, presentation is the tenant's zone, and
  the rendered string always carries its offset so a client cannot misread it.
  """

  use ExUnit.Case, async: true

  alias Aims.Time

  @utc ~U[2026-08-28 13:45:38.123456Z]

  describe "render/2" do
    test "renders IST as ISO 8601 with an explicit +05:30 offset" do
      assert Time.render(@utc, "Asia/Kolkata") == "2026-08-28T19:15:38.123456+05:30"
    end

    test "the offset is present, which is what makes the value unambiguous" do
      rendered = Time.render(@utc, "Asia/Kolkata")
      assert String.ends_with?(rendered, "+05:30")
      refute String.ends_with?(rendered, "Z")
    end

    test "round-trips back to the same instant" do
      {:ok, parsed, _offset} = DateTime.from_iso8601(Time.render(@utc, "Asia/Kolkata"))
      assert DateTime.compare(parsed, @utc) == :eq
    end

    test "IST is exactly five and a half hours ahead" do
      shifted = Time.shift(@utc, "Asia/Kolkata")
      assert shifted.hour == 19
      assert shifted.minute == 15
      assert shifted.utc_offset + shifted.std_offset == 19_800
    end

    test "renders other zones correctly, so a non-IST college would just work" do
      assert Time.render(@utc, "Etc/UTC") == "2026-08-28T13:45:38.123456Z"
      assert Time.render(@utc, "America/New_York") =~ ~r/-0[45]:00$/
    end

    test "nil renders as nil so optional timestamps serialise cleanly" do
      assert Time.render(nil, "Asia/Kolkata") == nil
      assert Time.render(nil) == nil
    end

    test "an unknown zone degrades to UTC rather than failing the request" do
      rendered = Time.render(@utc, "Mars/Olympus_Mons")
      # Still unambiguous: the offset reads +00:00 / Z.
      assert rendered == "2026-08-28T13:45:38.123456Z"
    end
  end

  describe "render/1" do
    test "uses the platform default zone" do
      assert Time.render(@utc) == Time.render(@utc, Time.default_zone())
    end

    test "the platform default is IST" do
      assert Time.default_zone() == "Asia/Kolkata"
    end
  end

  describe "shift/2" do
    test "nil passes through" do
      assert Time.shift(nil, "Asia/Kolkata") == nil
    end

    test "the shifted value is the same instant, not a different one" do
      assert DateTime.compare(Time.shift(@utc, "Asia/Kolkata"), @utc) == :eq
    end
  end

  describe "valid_zone?/1" do
    test "accepts real IANA zones" do
      assert Time.valid_zone?("Asia/Kolkata")
      assert Time.valid_zone?("Etc/UTC")
      assert Time.valid_zone?("America/New_York")
    end

    test "rejects nonsense, so a bad zone is caught on write not on render" do
      refute Time.valid_zone?("Mars/Olympus_Mons")
      refute Time.valid_zone?("IST")
      refute Time.valid_zone?("")
      refute Time.valid_zone?(nil)
      refute Time.valid_zone?(:asia_kolkata)
    end
  end

  describe "utc_now/0" do
    test "is UTC, because storage is always UTC" do
      assert Time.utc_now().time_zone == "Etc/UTC"
    end
  end
end
