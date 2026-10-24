defmodule Pinchflat.Media.ErrorSignatureTest do
  use Pinchflat.DataCase

  alias Pinchflat.Media.ErrorSignature

  describe "normalize/2" do
    test "returns the missing-details signature for nil, empty, and whitespace-only errors" do
      expected = %{signature: "missing", label: "No error details recorded"}

      assert ErrorSignature.normalize(nil) == expected
      assert ErrorSignature.normalize("") == expected
      assert ErrorSignature.normalize("  \n\t \r\n ") == expected
    end

    test "strips ANSI colors and handles CRLF line endings" do
      %{signature: signature, label: label} =
        ErrorSignature.normalize("\e[31mERROR: download failed\e[0m\r\nsecond line")

      assert label == "ERROR: download failed"
      assert signature == "line:error: download failed"
    end

    test "the first ERROR or WARNING diagnostic wins in input order" do
      assert %{label: "WARNING: first problem"} =
               ErrorSignature.normalize("WARNING: first problem\nERROR: second problem")

      assert %{label: "ERROR: first problem"} =
               ErrorSignature.normalize("ERROR: first problem\nWARNING: second problem")
    end

    test "a preamble-only error falls back to the first nonblank line" do
      %{signature: signature, label: label} =
        ErrorSignature.normalize("Running command with arguments\n\nContact support")

      assert label == "Running command with arguments"
      assert signature == "line:running command with arguments"
    end

    test "different known video IDs yield the same signature" do
      first = ErrorSignature.normalize("ERROR: video abc123def45 failed to stream", "abc123def45")
      second = ErrorSignature.normalize("ERROR: video xyz987wvuts failed to stream", "xyz987wvuts")

      assert first.signature == second.signature
      assert first.signature == "line:error: video <video-id> failed to stream"
      assert first.label == "ERROR: video <video-id> failed to stream"
    end

    test "all-letter video IDs normalize when supplied as media_id" do
      %{signature: signature} =
        ErrorSignature.normalize("ERROR: cannot extract abcdefghijk data", "abcdefghijk")

      assert signature == "line:error: cannot extract <video-id> data"
    end

    test "[youtube] ID: context normalizes without a supplied media_id" do
      %{label: label} =
        ErrorSignature.normalize("[youtube] dQw4w9WgXcQ: Downloading webpage failed")

      assert label == "[youtube] <video-id>: Downloading webpage failed"
    end

    test "ordinary eleven-letter words survive" do
      %{label: label} =
        ErrorSignature.normalize("ERROR: the requested content is unavailable here", "abc123def45")

      assert label == "ERROR: the requested content is unavailable here"
    end

    test "URLs, timestamps, retry counts, and variable numbers normalize" do
      %{signature: signature} =
        ErrorSignature.normalize(
          "ERROR: request to https://example.com/watch?v=abc deferred until 2024-05-06 07:08:09 after 3 attempts (took 12.5 seconds)"
        )

      assert signature ==
               "line:error: request to <url> deferred until <timestamp> after <n> attempts (took <n> seconds)"
    end

    test "HTTP 403 and HTTP 429 remain distinct" do
      forbidden = ErrorSignature.normalize("ERROR: HTTP Error 403: Forbidden")
      rate_limited = ErrorSignature.normalize("ERROR: HTTP Error 429: Too Many Requests")

      assert forbidden.signature == "line:error: http-403: forbidden"
      assert rate_limited.signature == "line:error: http-429: too many requests"
      refute forbidden.signature == rate_limited.signature
    end

    test "different diagnostics remain distinct" do
      first = ErrorSignature.normalize("ERROR: video unavailable")
      second = ErrorSignature.normalize("ERROR: sign in to confirm your age")

      refute first.signature == second.signature
    end

    test "label truncation does not truncate the signature" do
      normalized_line = "ERROR: " <> String.trim(String.duplicate("detail ", 80))
      %{signature: signature, label: label} = ErrorSignature.normalize(normalized_line)

      assert String.length(label) == 180
      assert signature == "line:" <> String.downcase(normalized_line)
      assert String.length(signature) > String.length(label)
    end
  end

  describe "group/1" do
    test "returns an empty list for an empty batch" do
      assert ErrorSignature.group([]) == []
    end

    test "counts signatures and preserves every original item" do
      items = [
        item(1, "ERROR: same problem"),
        item(2, "ERROR: same problem"),
        item(3, "ERROR: unique problem")
      ]

      [shared, unique] = ErrorSignature.group(items)

      assert shared.count == 2
      assert Enum.map(shared.items, & &1.id) == [1, 2]
      assert unique.count == 1
      assert Enum.map(unique.items, & &1.id) == [3]
    end

    test "sorts by count descending with a signature-ascending tie-break" do
      items = [
        item(1, "ERROR: beta issue"),
        item(2, "ERROR: gamma issue"),
        item(3, "ERROR: alpha issue"),
        item(4, "ERROR: alpha issue"),
        item(5, "ERROR: beta issue")
      ]

      groups = ErrorSignature.group(items)

      assert Enum.map(groups, & &1.count) == [2, 2, 1]

      assert Enum.map(groups, & &1.label) == [
               "ERROR: alpha issue",
               "ERROR: beta issue",
               "ERROR: gamma issue"
             ]
    end

    test "preserves original batch order inside each group" do
      items = [
        item(1, "ERROR: shared issue"),
        item(2, "ERROR: other issue"),
        item(3, "ERROR: shared issue"),
        item(4, "ERROR: shared issue")
      ]

      shared = Enum.find(ErrorSignature.group(items), &(&1.count == 3))

      assert Enum.map(shared.items, & &1.id) == [1, 3, 4]
    end

    test "exactly 20 signatures render 20 regular groups" do
      groups = ErrorSignature.group(signature_items(20))

      assert length(groups) == 20
      assert Enum.all?(groups, &(&1.signature != "overflow"))
      assert Enum.map(groups, & &1.id) == Enum.map(1..20, &"error-group-#{&1}")
    end

    test "more than 20 signatures render 19 regular groups plus overflow" do
      groups = ErrorSignature.group(signature_items(25))

      assert length(groups) == 20

      {main_groups, [overflow]} = Enum.split(groups, 19)

      assert Enum.all?(main_groups, &(&1.signature != "overflow"))

      assert Enum.map(main_groups, & &1.label) ==
               Enum.map(?a..?s, fn c -> "ERROR: #{<<c>>} failure" end)

      assert overflow.signature == "overflow"
      assert overflow.label == "Other signatures (6 groups)"
      assert overflow.count == 6
      assert overflow.id == "error-group-20"
    end

    test "overflow preserves every remaining item in original batch order" do
      overflow = ErrorSignature.group(signature_items(25)) |> List.last()

      assert Enum.map(overflow.items, & &1.id) == Enum.to_list(20..25)
    end

    test "each item appears exactly once across all groups" do
      items = signature_items(25)

      ids =
        items
        |> ErrorSignature.group()
        |> Enum.flat_map(& &1.items)
        |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.map(items, & &1.id)
    end
  end

  defp item(id, last_error) do
    %{id: id, media_id: nil, last_error: last_error}
  end

  # Count distinct one-of-a-kind signatures ("ERROR: a failure".."ERROR: y failure")
  # whose normalized signatures sort alphabetically in batch order
  defp signature_items(count) do
    Enum.map(1..count, fn i ->
      letter = <<?a + i - 1>>
      item(i, "ERROR: #{letter} failure")
    end)
  end
end
