import Foundation
import Testing
import WisperAgent
import WisperDomain

// Every tool, called the way an MCP client calls it, against the sample library:
// the product sync (yesterday), the Northwind call (3 days ago) and the 1:1 (6 days ago).

@Suite("Meeting tools")
struct MeetingToolTests {
  let harness = Harness()

  @Test func listIsSmallAndNewestFirst() async throws {
    let reply = try await harness.call("meetings_list")
    #expect(!reply.isError)
    #expect(reply.data["total"].int == 3)
    let meetings = reply.data["meetings"].array
    #expect(
      meetings.map { $0["title"].string } == [
        "Weekly product sync", "Customer call with Northwind", "1:1 with Jordan",
      ]
    )
    let first = meetings[0]
    #expect(first["id"].string == (await harness.meetings()[0].id.uuidString))
    // Times carry the user's own offset.
    #expect(first["started_at"].string == "2026-11-18T15:30:00+05:30")
    #expect(first["duration_minutes"].int == 31)
    #expect(first["status"].string == "ready")
    #expect(first["tags"].strings == ["product"])
    #expect(first["open_action_items"].int == 1)
    #expect(first["transcript_segments"].int == 4)
    #expect(first["summary"].string?.hasPrefix("The team confirmed") == true)
    // Lists never carry what was said.
    #expect(!reply.text.contains("Thanks for joining"))
  }

  @Test func listFilters() async throws {
    let limited = try await harness.call("meetings_list", #"{"limit":2}"#)
    #expect(limited.data["returned"].int == 2 && limited.data["total"].int == 3)

    let recent = try await harness.call("meetings_list", #"{"since":"2d"}"#)
    #expect(recent.data["meetings"].array.map { $0["title"].string } == ["Weekly product sync"])

    let dated = try await harness.call("meetings_list", #"{"since":"2026-11-14","until":"2026-11-18"}"#)
    #expect(dated.data["meetings"].array.map { $0["title"].string } == ["Customer call with Northwind"])

    let exact = try await harness.call("meetings_list", #"{"since":"2026-11-18T15:30:00+05:30"}"#)
    #expect(exact.data["total"].int == 1)
    let justAfter = try await harness.call("meetings_list", #"{"since":"2026-11-18T10:00:01Z"}"#)
    #expect(justAfter.data["total"].int == 0)

    let tagged = try await harness.call("meetings_list", #"{"tag":"CUSTOMER"}"#)
    #expect(tagged.data["meetings"].array.map { $0["title"].string } == ["Customer call with Northwind"])

    let failed = try await harness.call("meetings_list", #"{"status":"failed"}"#)
    #expect(failed.data["total"].int == 0 && failed.data["meetings"].array.isEmpty)

    let badDate = try await harness.call("meetings_list", #"{"since":"last tuesday"}"#)
    #expect(badDate.isError && badDate.text.contains("could not be read as a date"))
  }

  @Test func getReturnsNotesButNotTheTranscript() async throws {
    let meeting = await harness.meetings()[0]
    let reply = try await harness.call("meetings_get", #"{"meeting":"\#(meeting.id.uuidString)"}"#)
    #expect(!reply.isError)
    let data = reply.data
    #expect(data["id"].string == meeting.id.uuidString)
    #expect(data["title"].string == "Weekly product sync")
    #expect(data["ended_at"].string == "2026-11-18T16:01:00+05:30")
    #expect(data["summary"].string?.contains("launch is on track") == true)
    #expect(data["key_points"].strings.count == 3)
    #expect(data["decisions"].strings == ["Keep the launch date"])
    #expect(data["action_items"].array.count == 2)
    #expect(data["action_items"][0]["id"].string == meeting.notes?.actionItems[0].id.uuidString)
    #expect(data["action_items"][0]["owner"].string == "Alex")
    #expect(data["action_items"][1]["done"].bool == true)
    #expect(data["user_notes"].string == "Follow up on pricing page next week.")
    #expect(data["transcript_segments"].int == 4)
    #expect(data["speakers"].strings == ["Me", "Others"])
    #expect(data["uri"].string == "openwisper://meetings/\(meeting.id.uuidString)")
    #expect(!data["transcript"].exists)
    #expect(!reply.text.contains("Thanks for joining"))

    let full = try await harness.call("meetings_get", #"{"meeting":"latest","include_transcript":true}"#)
    #expect(full.data["transcript"].string == meeting.transcriptText)
  }

  @Test func getAMeetingWithoutNotes() async throws {
    let meeting = await harness.meetings()[2]
    let reply = try await harness.call("meetings_get", #"{"meeting":"\#(meeting.id.uuidString)"}"#)
    #expect(reply.data["ai_notes"].string == "none yet")
    #expect(!reply.data["summary"].exists)
    #expect(reply.data["tags"].array.isEmpty)
  }

  @Test func meetingsCanBeNamedInSeveralWays() async throws {
    let meeting = await harness.meetings()[1]
    let id = meeting.id.uuidString
    for reference in [
      id, id.lowercased(), String(id.prefix(8)), String(id.prefix(4)).lowercased(),
      id.replacingOccurrences(of: "-", with: ""), "openwisper://meetings/\(id)", "  \(id.prefix(13))  ",
    ] {
      let reply = try await harness.call("meetings_get", #"{"meeting":"\#(reference)"}"#)
      #expect(reply.data["id"].string == id, "\(reference) should find the meeting")
    }
    for latest in ["latest", "LATEST", "last"] {
      let reply = try await harness.call("meetings_get", #"{"meeting":"\#(latest)"}"#)
      #expect(reply.data["title"].string == "Weekly product sync")
    }
  }

  @Test func meetingsThatCannotBeFound() async throws {
    let unknown = try await harness.call(
      "meetings_get",
      #"{"meeting":"00000000-0000-0000-0000-000000000000"}"#
    )
    #expect(unknown.isError && unknown.text.contains("No meeting has the ID"))

    let tooShort = try await harness.call("meetings_get", #"{"meeting":"ab"}"#)
    #expect(tooShort.isError && tooShort.text.contains("is not a meeting ID"))

    let notAnID = try await harness.call("meetings_get", #"{"meeting":"the standup"}"#)
    #expect(notAnID.isError && notAnID.text.contains("\"latest\""))

    let empty = Harness(library: InMemoryLibrary())
    let nothing = try await empty.call("meetings_get", #"{"meeting":"latest"}"#)
    #expect(nothing.isError && nothing.text == "There are no meetings yet.")
  }

  @Test func aPrefixSharedByTwoMeetingsIsRefused() async throws {
    let first = Meeting(
      id: UUID(uuidString: "ABCD1111-0000-4000-8000-000000000001")!,
      title: "First",
      startedAt: Harness.now,
      status: .ready
    )
    let second = Meeting(
      id: UUID(uuidString: "ABCD2222-0000-4000-8000-000000000002")!,
      title: "Second",
      startedAt: Harness.now,
      status: .ready
    )
    let harness = Harness(library: InMemoryLibrary(meetings: [first, second]))
    let ambiguous = try await harness.call("meetings_get", #"{"meeting":"abcd"}"#)
    #expect(ambiguous.isError)
    #expect(
      ambiguous.text.contains("More than one meeting") && ambiguous.text.contains("First")
        && ambiguous.text.contains("Second")
    )
    let exact = try await harness.call("meetings_get", #"{"meeting":"abcd2"}"#)
    #expect(exact.data["title"].string == "Second")
  }

  @Test func transcriptAsLines() async throws {
    let reply = try await harness.call("meetings_transcript", #"{"meeting":"latest"}"#)
    #expect(!reply.isError)
    #expect(reply.data["total_segments"].int == 4)
    #expect(reply.data["returned_segments"].int == 4)
    #expect(!reply.data["next_offset"].exists)
    let lines = reply.data["transcript"].string?.split(separator: "\n").map(String.init) ?? []
    #expect(lines.count == 4)
    #expect(lines[0] == "[00:02] Me: Thanks for joining. Let's start with the launch date.")
    #expect(lines[1].hasPrefix("[00:10] Others: We're on track"))
  }

  @Test func transcriptByTimeSpeakerAndPage() async throws {
    let range = try await harness.call(
      "meetings_transcript",
      #"{"meeting":"latest","from":"0:20","to":"30"}"#
    )
    #expect(range.data["matching_segments"].int == 2)
    #expect(range.data["transcript"].string?.contains("[00:10]") == true)
    #expect(range.data["transcript"].string?.contains("[00:22]") == true)
    #expect(range.data["transcript"].string?.contains("[00:31]") == false)

    let mine = try await harness.call("meetings_transcript", #"{"meeting":"latest","speaker":"me"}"#)
    #expect(mine.data["matching_segments"].int == 2)
    #expect(mine.data["transcript"].string?.contains("Others:") == false)

    let firstPage = try await harness.call("meetings_transcript", #"{"meeting":"latest","limit":3}"#)
    #expect(firstPage.data["returned_segments"].int == 3)
    #expect(firstPage.data["next_offset"].int == 3)
    let secondPage = try await harness.call(
      "meetings_transcript",
      #"{"meeting":"latest","limit":3,"offset":3}"#
    )
    #expect(secondPage.data["returned_segments"].int == 1)
    #expect(!secondPage.data["next_offset"].exists)
    #expect(secondPage.data["transcript"].string?.hasPrefix("[00:31]") == true)

    let badTime = try await harness.call("meetings_transcript", #"{"meeting":"latest","from":"soon"}"#)
    #expect(badTime.isError && badTime.text.contains("could not be read as a time"))
  }

  @Test func searchReturnsSnippetsWithTimes() async throws {
    let reply = try await harness.call("meetings_search", #"{"query":"BILLING"}"#)
    #expect(!reply.isError)
    #expect(reply.data["matched_as"].string == "phrase")
    #expect(reply.data["meetings_matched"].int == 1)
    #expect(reply.data["total_matches"].int == 5)
    let result = reply.data["results"][0]
    #expect(result["title"].string == "Weekly product sync")
    let matches = result["matches"].array
    #expect(
      matches.map { $0["in"].string } == ["summary", "key_point", "action_item", "transcript", "transcript"]
    )
    let spoken = matches[3]
    #expect(spoken["at"].string == "00:10")
    #expect(spoken["speaker"].string == "Others")
    #expect(spoken["snippet"].string?.contains("billing migration") == true)
    #expect(!matches[0]["at"].exists)
    // Snippets, not meetings: nothing unrelated comes along.
    #expect(!reply.text.contains("onboarding copy ready"))
  }

  @Test func searchAcrossMeetingsAndLimits() async throws {
    let pricing = try await harness.call("meetings_search", #"{"query":"pricing"}"#)
    #expect(pricing.data["meetings_matched"].int == 2)
    #expect(pricing.data["results"][0]["matches"][0]["in"].string == "user_notes")
    #expect(pricing.data["results"][1]["matches"][0]["in"].string == "action_item")

    let capped = try await harness.call("meetings_search", #"{"query":"billing","per_meeting":2}"#)
    #expect(capped.data["results"][0]["matches"].array.count == 2)
    #expect(capped.data["results"][0]["more_matches"].int == 3)
    #expect(capped.data["returned_matches"].int == 2)

    let one = try await harness.call("meetings_search", #"{"query":"the","limit":1}"#)
    #expect(one.data["returned_matches"].int == 1 && one.data["results"].array.count == 1)

    let words = try await harness.call("meetings_search", #"{"query":"migration billing"}"#)
    #expect(words.data["matched_as"].string == "all_words")
    #expect((words.data["total_matches"].int ?? 0) >= 1)

    let byTag = try await harness.call("meetings_search", #"{"query":"customer"}"#)
    #expect(byTag.data["results"][0]["matches"].array.map { $0["in"].string }.contains("tag"))

    let recent = try await harness.call("meetings_search", #"{"query":"pricing","since":"2d"}"#)
    #expect(recent.data["meetings_matched"].int == 1)

    let nothing = try await harness.call("meetings_search", #"{"query":"zeppelin"}"#)
    #expect(
      !nothing.isError && nothing.data["total_matches"].int == 0 && nothing.data["results"].array.isEmpty
    )
  }

  @Test func longTextIsCutAroundTheMatch() async throws {
    var meeting = await harness.meetings()[2]
    let filler = String(repeating: "lorem ipsum dolor ", count: 40)
    meeting.segments = [
      TranscriptSegment(
        speaker: .named("Sam"),
        start: 754,
        end: 800,
        text: filler + "the zeppelin landed " + filler
      )
    ]
    await harness.library.save(meeting)
    let reply = try await harness.call("meetings_search", #"{"query":"zeppelin"}"#)
    let match = reply.data["results"][0]["matches"][0]
    #expect(match["at"].string == "12:34")
    #expect(match["speaker"].string == "Sam")
    let snippet = match["snippet"].string ?? ""
    #expect(snippet.contains("the zeppelin landed"))
    #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…"))
    #expect(snippet.count < 220)
  }

  @Test func addNoteKeepsWhatWasThere() async throws {
    let reply = try await harness.call(
      "meetings_add_note",
      #"{"meeting":"latest","text":"Sam says the migration is done.\n"}"#
    )
    #expect(!reply.isError)
    let saved = await harness.meetings()[0]
    #expect(saved.userNotes == "Follow up on pricing page next week.\n\nSam says the migration is done.")
    #expect(reply.data["user_notes"].string == saved.userNotes)

    let empty = await harness.meetings()[2]
    _ = try await harness.call(
      "meetings_add_note",
      #"{"meeting":"\#(empty.id.uuidString)","text":"First note"}"#
    )
    #expect(await harness.library.meeting(empty.id)?.userNotes == "First note")

    let blank = try await harness.call("meetings_add_note", #"{"meeting":"latest","text":""}"#)
    #expect(blank.isError)
  }

  @Test func updateChangesOnlyWhatIsGiven() async throws {
    let before = await harness.meetings()[0]
    let reply = try await harness.call(
      "meetings_update",
      #"{"meeting":"latest","title":"  Launch sync  ","add_tags":["Q4","product","q4"]}"#
    )
    #expect(!reply.isError)
    #expect(reply.data["title"].string == "Launch sync")
    #expect(reply.data["tags"].strings == ["product", "Q4"])
    let after = try #require(await harness.library.meeting(before.id))
    #expect(after.title == "Launch sync")
    #expect(after.userNotes == before.userNotes)
    #expect(after.segments == before.segments)
    #expect(after.notes == before.notes)

    _ = try await harness.call(
      "meetings_update",
      #"{"meeting":"latest","notes":"Rewritten.","remove_tags":["PRODUCT"]}"#
    )
    let rewritten = try #require(await harness.library.meeting(before.id))
    #expect(rewritten.userNotes == "Rewritten." && rewritten.tags == ["Q4"])

    _ = try await harness.call("meetings_update", #"{"meeting":"latest","tags":[],"notes":""}"#)
    let cleared = try #require(await harness.library.meeting(before.id))
    #expect(cleared.tags.isEmpty && cleared.userNotes.isEmpty)
  }

  @Test func updateErrors() async throws {
    let nothing = try await harness.call("meetings_update", #"{"meeting":"latest"}"#)
    #expect(nothing.isError && nothing.text.contains("Nothing to change"))
    let blank = try await harness.call("meetings_update", #"{"meeting":"latest","title":"   "}"#)
    #expect(blank.isError && blank.text.contains("must not be empty"))
    let badTags = try await harness.call("meetings_update", #"{"meeting":"latest","tags":[1,2]}"#)
    #expect(badTags.isError && badTags.text.contains("list of text"))
  }

  @Test func meetingsBeingWrittenByTheAppAreLeftAlone() async throws {
    let live = Meeting(title: "Live call", startedAt: Harness.now, status: .recording)
    let busy = Meeting(
      title: "Just ended",
      startedAt: Harness.now.addingTimeInterval(-600),
      status: .processing
    )
    await harness.library.save(live)
    await harness.library.save(busy)
    let note = try await harness.call(
      "meetings_add_note",
      #"{"meeting":"\#(live.id.uuidString)","text":"hi"}"#
    )
    #expect(note.isError && note.text.contains("still being recorded"))
    let rename = try await harness.call(
      "meetings_update",
      #"{"meeting":"\#(busy.id.uuidString)","title":"x"}"#
    )
    #expect(rename.isError && rename.text.contains("still writing the notes"))
    let action = try await harness.call("actions_add", #"{"meeting":"\#(live.id.uuidString)","text":"x"}"#)
    #expect(action.isError)
    let delete = try await harness.call("meetings_delete", #"{"meeting":"\#(live.id.uuidString)"}"#)
    #expect(delete.isError && delete.text.contains("Stop the recording first"))
    #expect(await harness.library.meeting(live.id) == live)
    // Reading them is fine.
    let read = try await harness.call("meetings_get", #"{"meeting":"\#(live.id.uuidString)"}"#)
    #expect(read.data["status"].string == "recording")
  }

  @Test func exportReturnsMarkdown() async throws {
    let meeting = await harness.meetings()[0]
    let reply = try await harness.call("meetings_export", #"{"meeting":"latest"}"#)
    #expect(reply.data["markdown"].string == meeting.markdown(timeZone: Harness.zone))
    #expect(reply.data["markdown"].string?.contains("## Transcript") == true)
    #expect(reply.data["markdown"].string?.contains("**Date:** 2026-11-18 15:30") == true)

    let short = try await harness.call("meetings_export", #"{"meeting":"latest","include_transcript":false}"#)
    #expect(short.data["markdown"].string?.contains("## Transcript") == false)
    #expect(short.data["markdown"].string?.contains("## Action items") == true)
    #expect(short.data["markdown"].string?.contains("**Length:** 31 min") == true)
  }

  @Test func exportSavesAFileAndNeverOverwrites() async throws {
    let folder = try harness.makeFolder()
    defer { harness.cleanUp() }
    let meeting = await harness.meetings()[0]
    // Where a file was saved is reported with every link followed, so compare real paths.
    let real = Harness.real(folder)

    let target = folder.appendingPathComponent("sync.md")
    let saved = try await harness.call("meetings_export", #"{"meeting":"latest","path":"\#(target.path)"}"#)
    #expect(!saved.isError)
    #expect(saved.data["path"].string == real + "/sync.md")
    #expect(!saved.data["markdown"].exists)
    #expect(try String(contentsOf: target, encoding: .utf8) == meeting.markdown(timeZone: Harness.zone))

    let again = try await harness.call("meetings_export", #"{"meeting":"latest","path":"\#(target.path)"}"#)
    #expect(again.isError && again.text.contains("already a file"))

    // A relative path is taken from the folder the tool was started in; a folder gets a file named for the meeting.
    let relative = try await harness.call("meetings_export", #"{"meeting":"latest","path":"notes.md"}"#)
    #expect(relative.data["path"].string == real + "/notes.md")
    let slashed = await harness.meetings()[2]
    let intoFolder = try await harness.call(
      "meetings_export",
      #"{"meeting":"\#(slashed.id.uuidString)","path":"\#(folder.path)"}"#
    )
    #expect(intoFolder.data["path"].string == real + "/2026-11-13 1-1 with Jordan.md")
    #expect(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("2026-11-13 1-1 with Jordan.md").path
      )
    )

    let nowhere = try await harness.call(
      "meetings_export",
      #"{"meeting":"latest","path":"/no/such/folder/x.md"}"#
    )
    #expect(nowhere.isError && nowhere.text.contains("Could not save"))
  }

  @Test func deleteNeedsAnIDAndRemovesTheMeeting() async throws {
    let meeting = await harness.meetings()[2]
    let latest = try await harness.call("meetings_delete", #"{"meeting":"latest"}"#)
    #expect(latest.isError && latest.text.contains("\"latest\" is not accepted"))
    #expect(await harness.meetings().count == 3)

    let reply = try await harness.call(
      "meetings_delete",
      #"{"meeting":"\#(meeting.id.uuidString.prefix(8))"}"#
    )
    #expect(!reply.isError && reply.data["deleted"].bool == true)
    #expect(reply.data["title"].string == "1:1 with Jordan")
    #expect(await harness.library.meeting(meeting.id) == nil)
    #expect(await harness.meetings().count == 2)

    let gone = try await harness.call("meetings_delete", #"{"meeting":"\#(meeting.id.uuidString)"}"#)
    #expect(gone.isError && gone.text.contains("No meeting has the ID"))
  }
}

@Suite("Action item tools")
struct ActionToolTests {
  let harness = Harness()

  @Test func listShowsOpenItemsFromEveryMeeting() async throws {
    let meetings = await harness.meetings()
    let reply = try await harness.call("actions_list")
    #expect(!reply.isError)
    #expect(reply.data["open"].int == 2 && reply.data["done"].int == 1)
    let items = reply.data["action_items"].array
    #expect(
      items.map { $0["text"].string } == [
        "Check in with Sam about the billing migration", "Send a summary and pricing",
      ]
    )
    #expect(items[0]["id"].string == meetings[0].notes?.actionItems[0].id.uuidString)
    #expect(items[0]["meeting_id"].string == meetings[0].id.uuidString)
    #expect(items[0]["meeting_title"].string == "Weekly product sync")
    #expect(items[0]["meeting_started_at"].string == "2026-11-18T15:30:00+05:30")
    #expect(items[0]["done"].bool == false)
  }

  @Test func listFilters() async throws {
    let done = try await harness.call("actions_list", #"{"status":"done"}"#)
    #expect(done.data["action_items"].array.map { $0["owner"].string } == ["Jordan"])
    let all = try await harness.call("actions_list", #"{"status":"all"}"#)
    #expect(all.data["returned"].int == 3)
    let jordan = try await harness.call("actions_list", #"{"owner":"jord"}"#)
    #expect(jordan.data["returned"].int == 0 && jordan.data["done"].int == 1)
    let customer = await harness.meetings()[1]
    let scoped = try await harness.call(
      "actions_list",
      #"{"meeting":"\#(customer.id.uuidString)","status":"all"}"#
    )
    #expect(scoped.data["action_items"].array.map { $0["text"].string } == ["Send a summary and pricing"])
    let limited = try await harness.call("actions_list", #"{"status":"all","limit":1}"#)
    #expect(limited.data["returned"].int == 1)
    let unknownMeeting = try await harness.call("actions_list", #"{"meeting":"ffffffff"}"#)
    #expect(unknownMeeting.isError)
  }

  @Test func addPutsANewOpenItemOnTheMeeting() async throws {
    let target = await harness.meetings()[2]  // has no AI notes yet
    let reply = try await harness.call(
      "actions_add",
      #"{"meeting":"\#(target.id.uuidString)","text":" Book the offsite ","owner":"Jordan"}"#
    )
    #expect(!reply.isError)
    let saved = try #require(await harness.library.meeting(target.id)?.notes?.actionItems)
    #expect(saved.count == 1)
    #expect(saved[0].text == "Book the offsite" && saved[0].owner == "Jordan" && !saved[0].done)
    #expect(reply.data["id"].string == saved[0].id.uuidString)
    #expect(reply.data["meeting_id"].string == target.id.uuidString)

    let missing = try await harness.call("actions_add", #"{"meeting":"latest"}"#)
    #expect(missing.isError && missing.text.contains("\"text\" is required"))
  }

  @Test func tickOffAndReopen() async throws {
    let meeting = await harness.meetings()[0]
    let item = try #require(meeting.notes?.actionItems[0])
    let done = try await harness.call("actions_set_done", #"{"action":"\#(item.id.uuidString.prefix(8))"}"#)
    #expect(!done.isError && done.data["done"].bool == true)
    #expect(await harness.library.meeting(meeting.id)?.notes?.actionItems[0].done == true)
    // Everything else about the meeting is untouched.
    #expect(await harness.library.meeting(meeting.id)?.segments == meeting.segments)
    #expect(await harness.library.meeting(meeting.id)?.notes?.summary == meeting.notes?.summary)

    let open = try await harness.call(
      "actions_set_done",
      #"{"action":"\#(item.id.uuidString)","done":false}"#
    )
    #expect(open.data["done"].bool == false)
    #expect(await harness.library.meeting(meeting.id)?.notes?.actionItems[0].done == false)
  }

  @Test func updateTextAndOwner() async throws {
    let meeting = await harness.meetings()[0]
    let item = try #require(meeting.notes?.actionItems[0])
    let reply = try await harness.call(
      "actions_update",
      #"{"action":"\#(item.id.uuidString)","text":"Call Sam","owner":"Priya"}"#
    )
    #expect(reply.data["text"].string == "Call Sam" && reply.data["owner"].string == "Priya")
    let cleared = try await harness.call("actions_update", #"{"action":"\#(item.id.uuidString)","owner":""}"#)
    #expect(!cleared.data["owner"].exists)
    let saved = try #require(await harness.library.meeting(meeting.id)?.notes?.actionItems[0])
    #expect(saved.text == "Call Sam" && saved.owner == nil && saved.id == item.id)

    let nothing = try await harness.call("actions_update", #"{"action":"\#(item.id.uuidString)"}"#)
    #expect(nothing.isError && nothing.text.contains("Nothing to change"))
    let blank = try await harness.call("actions_update", #"{"action":"\#(item.id.uuidString)","text":" "}"#)
    #expect(blank.isError)
  }

  @Test func removeTakesTheItemAway() async throws {
    let meeting = await harness.meetings()[0]
    let item = try #require(meeting.notes?.actionItems[1])
    let reply = try await harness.call("actions_remove", #"{"action":"\#(item.id.uuidString)"}"#)
    #expect(reply.data["removed"].bool == true && reply.data["text"].string == item.text)
    let left = try #require(await harness.library.meeting(meeting.id)?.notes?.actionItems)
    #expect(left.map(\.id) == [meeting.notes?.actionItems[0].id])
  }

  @Test func itemsThatCannotBeFound() async throws {
    let unknown = try await harness.call(
      "actions_set_done",
      #"{"action":"00000000-0000-0000-0000-000000000000"}"#
    )
    #expect(unknown.isError && unknown.text.contains("No action item has the ID"))
    let notAnID = try await harness.call("actions_remove", #"{"action":"the first one"}"#)
    #expect(notAnID.isError && notAnID.text.contains("is not an action item ID"))
    // "latest" names a meeting, never an action item.
    let latest = try await harness.call("actions_set_done", #"{"action":"latest"}"#)
    #expect(latest.isError)
  }
}

@Suite("Recording tools")
final class RecordingToolTests {
  let harness = Harness()

  // Asking the app leaves a ticket in the data folder.
  deinit { harness.cleanUp() }

  /// Makes the fake app behave like the real one: a start link creates a
  /// recording meeting, a stop link moves it on to "processing".
  private func appAnswers() {
    let library = harness.library
    harness.app.onLink { link in
      switch link {
      case .startMeeting(let title):
        await library.save(
          Meeting(title: title ?? "Untitled meeting", startedAt: Harness.now, status: .recording)
        )
      case .stopMeeting:
        for var meeting in await library.meetings(search: nil) where meeting.status == .recording {
          meeting.status = .processing
          meeting.endedAt = Harness.now
          await library.save(meeting)
        }
      default: break
      }
    }
  }

  @Test func statusWhenIdle() async throws {
    let reply = try await harness.call("recording_status")
    #expect(!reply.isError)
    #expect(reply.data["recording"].bool == false)
    #expect(reply.data["app_running"].bool == true)
    #expect(!reply.data["meeting"].exists)
    #expect(harness.app.links.isEmpty)
  }

  @Test func statusWhileRecording() async throws {
    let live = Meeting(
      title: "Board call",
      startedAt: Harness.now.addingTimeInterval(-125),
      status: .recording
    )
    await harness.library.save(live)
    await harness.library.save(
      Meeting(title: "Earlier", startedAt: Harness.now.addingTimeInterval(-9_000), status: .processing)
    )
    let reply = try await harness.call("recording_status")
    #expect(reply.data["recording"].bool == true)
    #expect(reply.data["meeting"]["id"].string == live.id.uuidString)
    #expect(reply.data["meeting"]["elapsed_seconds"].int == 125)
    #expect(reply.data["processing"].array.map { $0["title"].string } == ["Earlier"])

    harness.app.set(running: nil)
    let unknown = try await harness.call("recording_status")
    #expect(!unknown.data["app_running"].exists)
  }

  @Test func startAsksTheAppAndWaitsForTheMeeting() async throws {
    appAnswers()
    let reply = try await harness.call("recording_start", #"{"title":"Design review"}"#)
    #expect(!reply.isError)
    #expect(harness.app.links == [.startMeeting(title: "Design review")])
    #expect(reply.data["started"].bool == true)
    #expect(reply.data["meeting"]["title"].string == "Design review")
    #expect(reply.data["meeting"]["status"].string == "recording")
    let live = await harness.meetings().first { $0.status == .recording }
    #expect(reply.data["meeting"]["id"].string == live?.id.uuidString)
  }

  @Test func startWithoutATitleSendsThePlainLink() async throws {
    appAnswers()
    _ = try await harness.call("recording_start")
    #expect(harness.app.links.map(\.url.absoluteString) == ["openwisper://meetings/start"])
  }

  @Test func startDoesNothingWhenAlreadyRecording() async throws {
    let live = Meeting(title: "Board call", startedAt: Harness.now, status: .recording)
    await harness.library.save(live)
    let reply = try await harness.call("recording_start", #"{"title":"Another"}"#)
    #expect(!reply.isError)
    #expect(reply.data["started"].bool == false && reply.data["already_recording"].bool == true)
    #expect(reply.data["meeting"]["id"].string == live.id.uuidString)
    #expect(harness.app.links.isEmpty)
  }

  @Test func startSaysSoWhenTheAppDoesNotAnswer() async throws {
    harness.app.set(running: false)
    let closed = try await harness.call("recording_start")
    #expect(closed.isError)
    #expect(closed.text.contains("does not seem to be running"))
    #expect(harness.app.links == [.startMeeting(title: nil)])

    harness.app.set(running: true)
    let silent = try await harness.call("recording_start")
    #expect(silent.isError && silent.text.contains("did not start recording"))
    #expect(silent.text.contains("microphone access"))
  }

  @Test func startSaysSoWhenTheLinkCannotBeOpened() async throws {
    struct NoHandler: LocalizedError { var errorDescription: String? { "no app opens this link" } }
    let library = SampleData.library(now: Harness.now)
    let agent = WisperAgent(
      library: library,
      environment: WisperAgent.Environment(
        dataFolder: URL(fileURLWithPath: "/nowhere"),
        executablePath: "/nowhere/wisper",
        workingDirectory: URL(fileURLWithPath: "/nowhere"),
        openLink: { _ in throw NoHandler() },
        appIsRunning: { nil },
        appWait: .milliseconds(100)
      )
    )
    let out = Lines()
    let err = Lines()
    let io = WisperAgent.IO(
      input: AsyncStream { $0.finish() },
      output: { out.append($0) },
      error: { err.append($0) }
    )
    let code = await agent.run(["recording", "start"], io: io)
    #expect(code == 1)
    #expect(out.all.isEmpty)
    #expect(err.text.contains("Could not reach the Open Wisper app: no app opens this link"))
  }

  @Test func stopAsksTheAppAndReturnsTheMeeting() async throws {
    appAnswers()
    let live = Meeting(
      title: "Board call",
      startedAt: Harness.now.addingTimeInterval(-600),
      status: .recording
    )
    await harness.library.save(live)
    let reply = try await harness.call("recording_stop")
    #expect(!reply.isError)
    #expect(harness.app.links == [.stopMeeting])
    #expect(reply.data["stopped"].bool == true)
    #expect(reply.data["meeting"]["id"].string == live.id.uuidString)
    #expect(reply.data["meeting"]["status"].string == "processing")
  }

  @Test func stopWithNothingToStop() async throws {
    let reply = try await harness.call("recording_stop")
    #expect(!reply.isError)
    #expect(reply.data["stopped"].bool == false)
    #expect(harness.app.links.isEmpty)
  }

  @Test func stopSaysSoWhenTheAppDoesNotAnswer() async throws {
    await harness.library.save(Meeting(title: "Board call", startedAt: Harness.now, status: .recording))
    let reply = try await harness.call("recording_stop")
    #expect(reply.isError && reply.text.contains("did not stop recording"))
  }

  @Test func stopWhenTheAppThrowsTheMeetingAway() async throws {
    let live = Meeting(title: "Oops", startedAt: Harness.now, status: .recording)
    await harness.library.save(live)
    let library = harness.library
    harness.app.onLink { _ in await library.deleteMeeting(live.id) }
    let reply = try await harness.call("recording_stop")
    #expect(!reply.isError)
    #expect(reply.data["stopped"].bool == true && reply.data["kept"].bool == false)
  }
}

@Suite("Dictation, dictionary, snippet and settings tools")
struct LibraryToolTests {
  let harness = Harness()

  @Test func dictationsNewestFirst() async throws {
    let reply = try await harness.call("dictations_list")
    #expect(!reply.isError)
    #expect(reply.data["total"].int == 6 && reply.data["returned"].int == 6)
    let first = reply.data["dictations"][0]
    #expect(first["app"].string == "Slack")
    #expect(first["created_at"].string == "2026-11-19T17:20:00+05:30")
    #expect(first["text"].string?.hasPrefix("Sounds good") == true)
    #expect(first["words"].int == 15)
    #expect(first["seconds"].int == 6)
    #expect(!first["mode"].exists)
  }

  @Test func dictationsSearchAndFilters() async throws {
    let search = try await harness.call("dictations_list", #"{"query":"FLAT white"}"#)
    #expect(search.data["dictations"].array.map { $0["app"].string } == ["Messages"])
    let limited = try await harness.call("dictations_list", #"{"limit":2}"#)
    #expect(limited.data["returned"].int == 2 && limited.data["total"].int == 6)
    let today = try await harness.call("dictations_list", #"{"since":"today"}"#)
    #expect(today.data["total"].int == 3)
    let byApp = try await harness.call("dictations_list", #"{"app":"mail"}"#)
    #expect(byApp.data["dictations"].array.map { $0["app"].string } == ["Mail"])
    let none = try await harness.call("dictations_list", #"{"query":"zeppelin"}"#)
    #expect(!none.isError && none.data["total"].int == 0)
  }

  @Test func failedDictationsSayWhy() async throws {
    await harness.library.save(
      Dictation(
        createdAt: Harness.now,
        mode: .command,
        rawText: "",
        text: "",
        duration: 2.5,
        failure: "No speech was heard."
      )
    )
    let first = try await harness.call("dictations_list", #"{"limit":1}"#).data["dictations"][0]
    #expect(first["failure"].string == "No speech was heard.")
    #expect(first["mode"].string == "command")
    #expect(first["seconds"].value as? Double == 2.5)
  }

  @Test func dictionaryListAddRemove() async throws {
    let list = try await harness.call("dictionary_list")
    #expect(list.data["total"].int == 4)
    #expect(list.data["words"][0]["text"].string == "Kubernetes")
    #expect(list.data["words"][0]["replaces"].string == "cooper netties")
    #expect(!list.data["words"][1]["replaces"].exists)

    let added = try await harness.call("dictionary_add", #"{"text":" Anthropic ","replaces":"and tropic"}"#)
    #expect(added.data["added"].bool == true && added.data["text"].string == "Anthropic")
    let words = await harness.library.words()
    #expect(words.count == 5)
    #expect(words.first?.text == "Anthropic" && words.first?.replaces == "and tropic")

    let removed = try await harness.call("dictionary_remove", #"{"word":"anthropic"}"#)
    #expect(removed.data["removed"].bool == true)
    #expect(await harness.library.words().count == 4)

    let byID = try await harness.call(
      "dictionary_remove",
      #"{"word":"\#(words[1].id.uuidString.prefix(8))"}"#
    )
    #expect(byID.data["text"].string == words[1].text)

    let unknown = try await harness.call("dictionary_remove", #"{"word":"Zeppelin"}"#)
    #expect(unknown.isError && unknown.text.contains("There is no dictionary word"))
  }

  @Test func addingAWordTwiceKeepsOne() async throws {
    let same = try await harness.call("dictionary_add", #"{"text":"kubernetes"}"#)
    #expect(!same.isError && same.data["added"].bool == false)
    #expect(same.data["text"].string == "Kubernetes" && same.data["replaces"].string == "cooper netties")
    #expect(await harness.library.words().count == 4)

    let changed = try await harness.call(
      "dictionary_add",
      #"{"text":"Open Wisper","replaces":"open whisper"}"#
    )
    #expect(changed.data["added"].bool == false)
    let word = await harness.library.words().first { $0.text == "Open Wisper" }
    #expect(word?.replaces == "open whisper")
    #expect(await harness.library.words().count == 4)
  }

  @Test func snippetsListAddRemove() async throws {
    let list = try await harness.call("snippets_list")
    #expect(list.data["total"].int == 2)
    #expect(list.data["snippets"][0]["trigger"].string == "my calendar link")
    #expect(list.data["snippets"][0]["expansion"].string == "https://cal.example.com/alex")

    let added = try await harness.call("snippets_add", #"{"trigger":"sign off","expansion":"Thanks,\nAlex"}"#)
    #expect(!added.isError)
    let snippets = await harness.library.snippets()
    #expect(snippets.count == 3 && snippets[0].expansion == "Thanks,\nAlex")
    #expect(added.data["id"].string == snippets[0].id.uuidString)

    let twice = try await harness.call("snippets_add", #"{"trigger":"Sign Off","expansion":"Bye"}"#)
    #expect(twice.isError && twice.text.contains("already a snippet"))
    #expect(await harness.library.snippets().count == 3)

    let removed = try await harness.call("snippets_remove", #"{"snippet":"SIGN OFF"}"#)
    #expect(removed.data["removed"].bool == true)
    let byID = try await harness.call("snippets_remove", #"{"snippet":"\#(snippets[1].id.uuidString)"}"#)
    #expect(byID.data["trigger"].string == snippets[1].trigger)
    #expect(await harness.library.snippets().count == 1)

    let unknown = try await harness.call("snippets_remove", #"{"snippet":"nope"}"#)
    #expect(unknown.isError)
    let missing = try await harness.call("snippets_add", #"{"trigger":"x"}"#)
    #expect(missing.isError && missing.text.contains("\"expansion\" is required"))
  }

  @Test func settingsShowOnlyTheHarmlessParts() async throws {
    await harness.library.updateSettings {
      $0.language = "hi"
      $0.textModel = "gpt-5-mini"
      $0.apiBaseURL = "https://alex:hunter2@proxy.example.com/v1"
      $0.microphoneID = "BuiltInMicrophoneDevice"
    }
    let reply = try await harness.call("settings_get")
    #expect(!reply.isError)
    #expect(reply.data["user_name"].string == "Alex")
    #expect(reply.data["language"].string == "hi")
    #expect(reply.data["text_model"].string == "gpt-5-mini")
    #expect(reply.data["transcription_model"].string == Settings.defaultTranscriptionModel)
    #expect(reply.data["server"].string == "custom")
    #expect(reply.data["meetings"]["auto_summarize"].bool == true)
    #expect(reply.data["api_key"].string == "not available to this tool")
    // A server address can carry a password, so it is never shown.
    for secret in ["hunter2", "proxy.example.com", "BuiltInMicrophoneDevice"] {
      #expect(!reply.text.contains(secret))
      #expect(!(await harness.cli("settings", "get").out.contains(secret)))
    }

    let auto = try await Harness().call("settings_get")
    #expect(auto.data["language"].string == "auto" && auto.data["server"].string == "openai")
  }
}
