defmodule Selecto.DB.SubscriptionPublisherTest do
  use ExUnit.Case, async: true

  alias Selecto.DB.SubscriptionPublisher

  defmodule Complete do
    def publisher_capabilities(:connection, %{}) do
      {:ok,
       %{
         backend: :synthetic,
         available: true,
         invariants: Map.new(SubscriptionPublisher.required_invariants(), &{&1, true})
       }}
    end
  end

  defmodule Partial do
    def publisher_capabilities(:connection, %{}) do
      {:ok,
       %{
         backend: :synthetic,
         available: true,
         invariants:
           SubscriptionPublisher.required_invariants()
           |> Map.new(&{&1, true})
           |> Map.put(:durable_resume, false)
       }}
    end
  end

  test "accepts only a complete publisher profile" do
    assert :ok = SubscriptionPublisher.preflight(Complete, :connection)

    assert {:error, {:missing_publisher_invariants, [:durable_resume]}} =
             SubscriptionPublisher.preflight(Partial, :connection)
  end

  test "unavailable profiles name every required invariant and fail closed" do
    assert {:ok, profile} =
             SubscriptionPublisher.unavailable(:mongodb, :snapshot_change_gap, %{
               tenant_scope: true
             })

    refute profile.available
    assert profile.reason == :snapshot_change_gap
    assert profile.invariants.tenant_scope
    refute profile.invariants.snapshot_watermark
  end
end
