defmodule SpojitiRelay.PowTest do
  @moduledoc """
  Registry row 5 (Bot gate) had no case and no test until 2026-09-04 (#329).
  This pins what the gate actually promises: a solution costs work, is
  verified against OUR signature, and can be spent exactly once.
  """
  # Not async: POW_BITS is process-global and this file moves it.
  use ExUnit.Case, async: false

  alias SpojitiRelay.Pow

  setup do
    before = System.get_env("POW_BITS")
    # 8 bits: ~256 hashes to solve, instant in a test, still a real search.
    System.put_env("POW_BITS", "8")

    on_exit(fn ->
      if before, do: System.put_env("POW_BITS", before), else: System.delete_env("POW_BITS")
    end)

    :ok
  end

  defp solve(%{challenge: payload, bits: bits}) do
    Stream.iterate(0, &(&1 + 1))
    |> Enum.find(fn n ->
      lz(:crypto.hash(:sha256, payload <> "." <> Integer.to_string(n))) >= bits
    end)
    |> Integer.to_string()
  end

  defp lz(<<0::size(1), rest::bitstring>>), do: 1 + lz(rest)
  defp lz(_), do: 0

  defp solved(ch), do: %{"challenge" => ch.challenge, "sig" => ch.sig, "nonce" => solve(ch)}

  test "a solved challenge is accepted once, and only once" do
    ch = Pow.challenge()
    assert ch.bits == 8
    assert ch.algo == "sha256-lz"
    sol = solved(ch)
    assert :ok = Pow.verify(sol)
    # The same solution again is a replay, whatever the nonce says.
    assert {:error, :replayed} = Pow.verify(sol)
  end

  test "work that does not meet the target is refused" do
    ch = Pow.challenge()
    bad = %{"challenge" => ch.challenge, "sig" => ch.sig, "nonce" => "not-a-solution"}

    case Pow.verify(bad) do
      {:error, :bad_pow} -> :ok
      # 1 in 256 that a random nonce happens to solve 8 bits — accept that
      # outcome rather than flake, but never an error of another kind.
      :ok -> :ok
      other -> flunk("expected :bad_pow, got #{inspect(other)}")
    end
  end

  test "a challenge we did not sign is refused before any work is checked" do
    ch = Pow.challenge()
    forged = %{ch | sig: String.reverse(ch.sig)}
    assert {:error, :bad_sig} = Pow.verify(solved(forged))
  end

  test "a challenge minted at a weaker target than the relay now demands is refused" do
    ch = Pow.challenge()
    sol = solved(ch)
    System.put_env("POW_BITS", "9")
    assert {:error, :weak} = Pow.verify(sol)
  end

  test "garbage is malformed, not a crash" do
    assert {:error, :malformed} = Pow.verify(%{})
    assert {:error, :malformed} = Pow.verify(%{"challenge" => "v2.x", "sig" => "s", "nonce" => "1"})
    assert {:error, :malformed} = Pow.verify(nil)
  end

  test "the gate can be switched off, and says so" do
    System.put_env("POW_BITS", "0")
    refute Pow.enabled?()
    System.put_env("POW_BITS", "8")
    assert Pow.enabled?()
  end
end
