// go_backend/spotify_personal_test.go
package gobackend

import (
	"encoding/json"
	"testing"
)

func TestFormatSpotifyHomeFeedResponse(t *testing.T) {
	raw := []byte(`{
		"data": {
			"home": {
				"greeting": {"text": "Good evening"},
				"sectionContainer": {
					"sections": {
						"items": [
							{
								"uri": "section:1",
								"data": {"title": {"text": "Made for you"}},
								"sectionItems": {
									"items": [
										{
											"content": {
												"data": {
													"__typename": "Track",
													"uri": "spotify:track:abc123",
													"name": "Song Name",
													"albumOfTrack": {
														"name": "Album Name",
														"uri": "spotify:album:def456",
														"coverArt": {"sources": [{"url": "https://img/1.jpg"}]}
													},
													"artists": {"items": [{"profile": {"name": "Artist A"}}]},
													"duration": {"totalMilliseconds": 210000}
												}
											}
										}
									]
								}
							}
						]
					}
				}
			}
		}
	}`)

	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	result := formatSpotifyHomeFeedResponse(parsed)

	if result["greeting"] != "Good evening" {
		t.Fatalf("expected greeting %q, got %v", "Good evening", result["greeting"])
	}
	sections, ok := result["sections"].([]map[string]any)
	if !ok || len(sections) != 1 {
		t.Fatalf("expected 1 section, got %v", result["sections"])
	}
	items, ok := sections[0]["items"].([]map[string]any)
	if !ok || len(items) != 1 {
		t.Fatalf("expected 1 item, got %v", sections[0]["items"])
	}
	item := items[0]
	if item["id"] != "abc123" || item["type"] != "track" {
		t.Fatalf("unexpected item id/type: %v/%v", item["id"], item["type"])
	}
	if item["name"] != "Song Name" || item["artists"] != "Artist A" {
		t.Fatalf("unexpected item name/artists: %v/%v", item["name"], item["artists"])
	}
	if item["album_name"] != "Album Name" || item["album_id"] != "def456" {
		t.Fatalf("unexpected album fields: %v/%v", item["album_name"], item["album_id"])
	}
	if item["cover_url"] != "https://img/1.jpg" {
		t.Fatalf("unexpected cover_url: %v", item["cover_url"])
	}
	if item["duration_ms"] != 210000 {
		t.Fatalf("unexpected duration_ms: %v", item["duration_ms"])
	}
	if item["provider_id"] != "spotify-personal" {
		t.Fatalf("expected provider_id spotify-personal, got %v", item["provider_id"])
	}
}

// TestFormatSpotifyHomeFeedItemUnknownTypeIsNotDropped guards against the
// item-level formatter silently discarding item types it doesn't have
// specific field-path handling for (e.g. episode/show/audiobook). The
// reference extension (index.js:1890-1939) has no else/default branch that
// drops the item — it always emits id/uri/type/name with cover/artists/etc.
// left empty. Dropping the item here would (via the len(items) == 0 guard in
// formatSpotifyHomeFeedResponse) silently vanish whole sections made up
// entirely of unhandled types.
func TestFormatSpotifyHomeFeedItemUnknownTypeIsNotDropped(t *testing.T) {
	raw := []byte(`{
		"content": {
			"data": {
				"__typename": "PodcastEpisode",
				"uri": "spotify:episode:ep789",
				"name": "Episode Name"
			}
		}
	}`)

	var parsed any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	item, ok := formatSpotifyHomeFeedItem(parsed)
	if !ok {
		t.Fatalf("expected unknown item type %q to still be emitted, got ok=false", "episode")
	}
	if item["id"] != "ep789" || item["type"] != "episode" {
		t.Fatalf("unexpected item id/type: %v/%v", item["id"], item["type"])
	}
	if item["name"] != "Episode Name" {
		t.Fatalf("unexpected item name: %v", item["name"])
	}
	if item["cover_url"] != "" {
		t.Fatalf("expected empty cover_url for unhandled type, got %v", item["cover_url"])
	}
	if item["provider_id"] != "spotify-personal" {
		t.Fatalf("expected provider_id spotify-personal, got %v", item["provider_id"])
	}
}

// TestFormatSpotifyHomeFeedResponseKeepsSectionOfOnlyUnknownTypes confirms a
// section made up entirely of unhandled item types (e.g. "Your shows") is
// not silently dropped by the len(items) == 0 guard now that unknown types
// are emitted instead of skipped.
func TestFormatSpotifyHomeFeedResponseKeepsSectionOfOnlyUnknownTypes(t *testing.T) {
	raw := []byte(`{
		"data": {
			"home": {
				"greeting": {"text": "Good evening"},
				"sectionContainer": {
					"sections": {
						"items": [
							{
								"uri": "section:shows",
								"data": {"title": {"text": "Your shows"}},
								"sectionItems": {
									"items": [
										{
											"content": {
												"data": {
													"__typename": "PodcastEpisode",
													"uri": "spotify:episode:ep789",
													"name": "Episode Name"
												}
											}
										}
									]
								}
							}
						]
					}
				}
			}
		}
	}`)

	var parsed map[string]any
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("failed to parse fixture: %v", err)
	}

	result := formatSpotifyHomeFeedResponse(parsed)

	sections, ok := result["sections"].([]map[string]any)
	if !ok || len(sections) != 1 {
		t.Fatalf("expected the 'Your shows' section to survive, got %v", result["sections"])
	}
	items, ok := sections[0]["items"].([]map[string]any)
	if !ok || len(items) != 1 {
		t.Fatalf("expected 1 item in the shows section, got %v", sections[0]["items"])
	}
	if items[0]["type"] != "episode" || items[0]["id"] != "ep789" {
		t.Fatalf("unexpected item id/type: %v/%v", items[0]["id"], items[0]["type"])
	}
}
