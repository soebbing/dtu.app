defmodule DtuApp.Accounts.PasskeyTest do
  use DtuApp.DataCase, async: true

  alias DtuApp.Accounts.Passkey
  import DtuApp.AccountsFixtures

  describe "registration_changeset/2" do
    test "requires user_id, credential_id, public_key, alg, friendly_name" do
      cs = Passkey.registration_changeset(%Passkey{}, %{})
      refute cs.valid?
      assert %{user_id: ["can't be blank"]} = errors_on(cs)
      assert %{credential_id: ["can't be blank"]} = errors_on(cs)
      assert %{public_key: ["can't be blank"]} = errors_on(cs)
      assert %{alg: ["can't be blank"]} = errors_on(cs)
      assert %{friendly_name: ["can't be blank"]} = errors_on(cs)
    end

    test "rejects empty friendly_name" do
      user = user_fixture()
      cs = Passkey.registration_changeset(%Passkey{}, base_attrs(user, %{friendly_name: ""}))
      assert %{friendly_name: _} = errors_on(cs)
    end

    test "rejects friendly_name longer than 60 chars" do
      user = user_fixture()

      cs =
        Passkey.registration_changeset(
          %Passkey{},
          base_attrs(user, %{friendly_name: String.duplicate("x", 61)})
        )

      assert %{friendly_name: _} = errors_on(cs)
    end

    test "accepts a valid changeset" do
      user = user_fixture()

      assert {:ok, %Passkey{}} =
               %Passkey{}
               |> Passkey.registration_changeset(base_attrs(user, %{}))
               |> Repo.insert()
    end

    test "enforces unique credential_id" do
      user = user_fixture()
      cred_id = :crypto.strong_rand_bytes(32)
      insert_passkey(user, %{credential_id: cred_id})

      cs =
        %Passkey{}
        |> Passkey.registration_changeset(base_attrs(user, %{credential_id: cred_id}))

      assert {:error, cs} = Repo.insert(cs)
      assert %{credential_id: ["has already been taken"]} = errors_on(cs)
    end
  end

  describe "usage_changeset/2" do
    test "accepts strict-greater-than sign_count" do
      passkey = insert_passkey(user_fixture(), %{sign_count: 5})
      cs = Passkey.usage_changeset(passkey, %{sign_count: 6, last_used_at: DateTime.utc_now()})
      assert cs.valid?
    end

    test "rejects equal sign_count" do
      passkey = insert_passkey(user_fixture(), %{sign_count: 5})
      cs = Passkey.usage_changeset(passkey, %{sign_count: 5, last_used_at: DateTime.utc_now()})
      refute cs.valid?
      assert %{sign_count: _} = errors_on(cs)
    end

    test "rejects smaller sign_count" do
      passkey = insert_passkey(user_fixture(), %{sign_count: 5})
      cs = Passkey.usage_changeset(passkey, %{sign_count: 4, last_used_at: DateTime.utc_now()})
      refute cs.valid?
    end

    test "requires last_used_at" do
      passkey = insert_passkey(user_fixture(), %{})
      cs = Passkey.usage_changeset(passkey, %{sign_count: 1})
      refute cs.valid?
    end
  end

  describe "passkey_fixture/2" do
    test "User-struct form attaches the passkey to the supplied user" do
      user = user_fixture()
      passkey = passkey_fixture(user, %{})
      assert passkey.user_id == user.id
    end

    test "attrs-map form respects an explicit user_id in overrides" do
      user = user_fixture()
      passkey = passkey_fixture(%{user_id: user.id}, %{friendly_name: "Custom"})
      assert passkey.user_id == user.id
      assert passkey.friendly_name == "Custom"
    end
  end

  # ----- helpers -----

  defp base_attrs(user, overrides) do
    Enum.into(overrides, %{
      user_id: user.id,
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: :crypto.strong_rand_bytes(65),
      sign_count: 0,
      alg: -7,
      transports: [],
      friendly_name: "Test"
    })
  end

  defp insert_passkey(user, overrides) do
    {:ok, pk} =
      %Passkey{}
      |> Passkey.registration_changeset(base_attrs(user, overrides))
      |> Repo.insert()

    pk
  end
end
