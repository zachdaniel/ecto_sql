defmodule Ecto.Integration.MergeTest do
  use Ecto.Integration.Case, async: true

  alias Ecto.Integration.TestRepo
  alias Ecto.Integration.Post
  import Ecto.Query

  @moduletag :merge

  # TODO: Postgrex does not yet parse the "MERGE N" command tag,
  # so num_rows is 0 when RETURNING is not used. Tests that don't
  # use RETURNING verify correctness by reading back the data instead
  # of asserting on the count.

  describe "merge_all" do
    test "basic merge updates matched rows" do
      TestRepo.insert!(%Post{title: "first", visits: 1})
      TestRepo.insert!(%Post{title: "second", visits: 2})

      [%{id: id1}, %{id: id2}] = TestRepo.all(from p in Post, order_by: p.title, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id1, title: "first updated", visits: 10},
          %{id: id2, title: "second updated", visits: 20}
        ], on: [:id])

      posts = TestRepo.all(from p in Post, order_by: p.id, select: p)
      assert [%{title: "first updated", visits: 10}, %{title: "second updated", visits: 20}] = posts
    end

    test "merge with returning" do
      TestRepo.insert!(%Post{title: "original", visits: 5})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, [returned]} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "merged", visits: 50}
        ], on: [:id], returning: [:id, :title, :visits])

      assert returned.id == id
      assert returned.title == "merged"
      assert returned.visits == 50
    end

    test "merge with returning true" do
      TestRepo.insert!(%Post{title: "original", visits: 5})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, [returned]} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "merged", visits: 50}
        ], on: [:id], returning: true)

      assert returned.id == id
      assert returned.title == "merged"
    end

    test "merge with specific update columns" do
      TestRepo.insert!(%Post{title: "keep me", visits: 1})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      # Only update visits, not title
      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "ignored", visits: 100}
        ], on: [:id], update: [:visits])

      post = TestRepo.get!(Post, id)
      assert post.title == "keep me"
      assert post.visits == 100
    end

    test "merge with expression-based updates" do
      TestRepo.insert!(%Post{title: "original", visits: 5})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "merged"}
        ], on: [:id], update: [:title], updates: [inc: [visits: 10]])

      post = TestRepo.get!(Post, id)
      assert post.title == "merged"
      assert post.visits == 15
    end

    test "merge with no matching rows is a no-op" do
      TestRepo.insert!(%Post{title: "existing", visits: 1})

      {0, nil} =
        TestRepo.merge_all(Post, [
          %{id: -1, title: "ghost", visits: 999}
        ], on: [:id])

      [post] = TestRepo.all(Post)
      assert post.title == "existing"
    end

    test "merge with empty entries" do
      assert {0, nil} = TestRepo.merge_all(Post, [], on: [:id])
      assert {0, []} = TestRepo.merge_all(Post, [], on: [:id], returning: true)
    end

    test "merge with composite match keys" do
      TestRepo.insert!(%Post{title: "match both", visits: 1, public: true})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "match both", visits: 42, public: true}
        ], on: [:id, :title])

      post = TestRepo.get!(Post, id)
      assert post.visits == 42
    end

    # Raw table names without a schema have no type info for VALUES casting.
    # This is a known limitation — use {source, schema} tuples instead.

    test "merge with {source, schema} tuple" do
      TestRepo.insert!(%Post{title: "tuple", visits: 1})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all({"posts", Post}, [
          %{id: id, title: "tuple updated", visits: 2}
        ], on: [:id])

      post = TestRepo.get!(Post, id)
      assert post.title == "tuple updated"
    end
  end

  describe "on_not_matched: :insert" do
    test "inserts non-matching rows" do
      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: -1, title: "brand new", visits: 1}
        ], on: [:id], on_not_matched: :insert)

      [post] = TestRepo.all(Post)
      assert post.title == "brand new"
      assert post.visits == 1
    end

    test "upsert: updates matched, inserts unmatched" do
      TestRepo.insert!(%Post{title: "existing", visits: 5})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "updated", visits: 10},
          %{id: -1, title: "inserted", visits: 20}
        ], on: [:id], on_not_matched: :insert)

      posts = TestRepo.all(from p in Post, order_by: p.title, select: p)
      assert [%{title: "inserted", visits: 20}, %{title: "updated", visits: 10}] = posts
    end

    test "insert with specific columns" do
      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: -1, title: "partial", visits: 99}
        ], on: [:id], on_not_matched: {:insert, [:id, :title]})

      [post] = TestRepo.all(Post)
      assert post.title == "partial"
      # visits should be nil since we only inserted id and title
      assert is_nil(post.visits)
    end

    test "on_not_matched with returning" do
      {_count, [returned]} =
        TestRepo.merge_all(Post, [
          %{id: -1, title: "new with return", visits: 7}
        ], on: [:id], on_not_matched: :insert, returning: [:title, :visits])

      assert returned.title == "new with return"
      assert returned.visits == 7
    end
  end

  describe "returning with merge_action()" do
    test "unsafe_fragment returning distinguishes inserted vs updated rows" do
      TestRepo.insert!(%Post{title: "existing", visits: 1})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, rows} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "updated", visits: 10},
          %{id: -1, title: "inserted", visits: 20}
        ],
          on: [:id],
          on_not_matched: :insert,
          returning: {:unsafe_fragment, ~s[merge_action() AS action, t."id", t."title"]}
        )

      assert length(rows) == 2

      actions = Map.new(rows, fn [action, id, _title] -> {id, action} end)
      assert actions[id] == "UPDATE"

      [insert_row] = Enum.filter(rows, fn [action, _, _] -> action == "INSERT" end)
      assert Enum.at(insert_row, 2) == "inserted"
    end
  end

  describe "when_matched" do
    test "do_nothing skips matched rows" do
      TestRepo.insert!(%Post{title: "untouched", visits: 1})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "should not apply", visits: 999}
        ], on: [:id], when_matched: :do_nothing)

      post = TestRepo.get!(Post, id)
      assert post.title == "untouched"
      assert post.visits == 1
    end

    test "insert-only merge using do_nothing + on_not_matched" do
      TestRepo.insert!(%Post{title: "existing", visits: 1})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "skip me", visits: 999},
          %{id: -1, title: "insert me", visits: 42}
        ], on: [:id], when_matched: :do_nothing, on_not_matched: :insert)

      posts = TestRepo.all(from p in Post, order_by: p.title, select: p)
      assert [%{title: "existing", visits: 1}, %{title: "insert me", visits: 42}] = posts
    end

    test "conditional when_matched with unsafe_fragment" do
      TestRepo.insert!(%Post{title: "old", visits: 5, public: true})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      # Only update when the source visits > 10
      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "should not update", visits: 3}
        ], on: [:id], when_matched: [
          {{:unsafe_fragment, ~s[v."visits" > 10]}, update: [:title, :visits]},
          :do_nothing
        ])

      post = TestRepo.get!(Post, id)
      assert post.title == "old"
      assert post.visits == 5

      # Now with visits > 10, it should update
      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "updated!", visits: 20}
        ], on: [:id], when_matched: [
          {{:unsafe_fragment, ~s[v."visits" > 10]}, update: [:title, :visits]},
          :do_nothing
        ])

      post = TestRepo.get!(Post, id)
      assert post.title == "updated!"
      assert post.visits == 20
    end

    test "multiple conditional when_matched clauses (expression groups)" do
      TestRepo.insert!(%Post{title: "row1", visits: 10})
      TestRepo.insert!(%Post{title: "row2", visits: 20})
      [%{id: id1}, %{id: id2}] = TestRepo.all(from p in Post, order_by: p.title, select: p)

      # Simulate expression groups: group 1 increments visits, group 2 sets visits to 0
      # We add an "expr_group" column to VALUES to discriminate
      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id1, title: "row1", visits: 5, counter: 1},
          %{id: id2, title: "row2", visits: 0, counter: 2}
        ], on: [:id], when_matched: [
          {{:unsafe_fragment, ~s[v."counter" = 1]},
            update: [:title], updates: [inc: [visits: 5]]},
          {{:unsafe_fragment, ~s[v."counter" = 2]},
            update: [:title], updates: [set: [visits: 0]]}
        ])

      posts = TestRepo.all(from p in Post, order_by: p.title, select: p)
      assert [%{title: "row1", visits: 15}, %{title: "row2", visits: 0}] = posts
    end

    test "conditional when_matched with on_not_matched" do
      TestRepo.insert!(%Post{title: "existing", visits: 1})
      [%{id: id}] = TestRepo.all(from p in Post, select: p)

      {_count, nil} =
        TestRepo.merge_all(Post, [
          %{id: id, title: "updated", visits: 100},
          %{id: -1, title: "new post", visits: 42}
        ], on: [:id],
           when_matched: [
             {{:unsafe_fragment, ~s[v."visits" > 50]}, update: [:title, :visits]},
             :do_nothing
           ],
           on_not_matched: :insert)

      posts = TestRepo.all(from p in Post, order_by: p.title, select: p)
      assert [%{title: "new post", visits: 42}, %{title: "updated", visits: 100}] = posts
    end
  end
end
