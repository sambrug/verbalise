#!/usr/bin/env python3
"""Generate the text-pipeline fixture file from the Python implementation.

swift_migration_plan.md §6: the Python functions are the oracle for the Swift
port. Rather than hand-writing expected values (and hand-copying whatever bug
or subtlety the regexes actually have), run the real functions over a corpus of
inputs and record what they produce. The Swift tests then assert equality
against that record.

Run from the repo root:

    .venv/bin/python3 swift/Scripts/generate-fixtures.py

Re-run it whenever the Python pipeline changes; a diff in the fixture file is
the signal that the Swift port needs a matching change.
"""
import json
import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

import daemon  # noqa: E402

OUT = REPO_ROOT / "swift/Tests/OpenWhisperCoreTests/Fixtures/text-pipeline.json"

# --- Inputs -----------------------------------------------------------------

CLEAN_INPUTS = [
    # Nothing to strip.
    "Hello there, this is a normal sentence.",
    "Book the meeting for Tuesday",
    "",
    # Single trailing hallucinations.
    "Book the meeting for Tuesday. Thanks for watching!",
    "Book the meeting for Tuesday. Thank you.",
    "Some real content here. Thanks",
    "Some real content here. Subscribe",
    "Some real content here. Please subscribe.",
    "Some real content here. Like and subscribe!",
    "Some real content here. Bye",
    "Some real content here. Bye for now.",
    "Some real content here. See you next time.",
    "Some real content here. See you in the next video",
    # Stacked -- needs the repeat-until-stable loop.
    "Real content. Thank you. Thanks for watching.",
    "Real content... Thank you.",
    "Real content. Thank you. ...",
    # Ellipsis handling.
    "Trailing ellipsis...",
    "Trailing unicode ellipsis…",
    "Dot groups at the end. . .",
    "Hello there. ...",
    "Spaced groups ... ... ...",
    # A real sentence-final period must survive.
    "This sentence simply ends.",
    "Ends with a question?",
    # Degenerate results.
    "...",
    "…",
    ". . .",
    "   ",
    "Thank you.",
    "Bye.",
    # Case insensitivity.
    "Real content. THANK YOU!",
    "Real content. thanks for watching",
    # Words that merely contain a trigger word must not be stripped
    # (the patterns are \b-anchored).
    "We discussed the subscriber count",
    "He said goodbye to the team",
    # Repetition loops.
    "Region Region Region Region Region Region Region Region",
    "the the the the the the the the the the",
    " ".join(["spam"] * 30),
    # 15+ words, most common just over half.
    " ".join(["x"] * 9 + ["a", "b", "c", "d", "e", "f"]),
    # Legitimate repetition that must NOT trip the detector.
    "I said no no no but they went ahead anyway with the plan",
    "very very very good",
]

JOIN_INPUTS = [
    [],
    [""],
    ["Just one chunk"],
    # Lowercase continuation: the boundary period is spurious, drop it.
    ["I was still talking.", "and continuing on"],
    ["First part.", "second part.", "third part"],
    # Capital start: a real sentence end, keep the period.
    ["That was the end.", "This is new"],
    # No punctuation at the boundary: leave alone.
    ["No punctuation here", "and more text"],
    # Closing quote/bracket after the punctuation.
    ['He said "that is it."', "and then left"],
    ["A parenthetical (like this.)", "continues here"],
    # Question and exclamation marks behave the same as periods.
    ["Was that it?", "apparently not"],
    ["Stop!", "he shouted"],
    # Whitespace-only chunks are dropped.
    ["First chunk.", "   ", "second chunk"],
    ["  padded  ", "  chunks  "],
]

PHONETIC_INPUTS = [
    ("The ethanol report is due", [["ethanol", "FNOL"]]),
    ("ETHANOL and Ethanol and ethanol", [["ethanol", "FNOL"]]),
    # Whole-word only: must not touch "methanol".
    ("The methanol sample", [["ethanol", "FNOL"]]),
    ("no corrections configured", []),
    ("", [["a", "b"]]),
    # Applied in order; the second can act on the first's output.
    ("alpha beta", [["alpha", "beta"], ["beta", "gamma"]]),
    # Multi-word keys.
    ("please file a new claim today", [["new claim", "NewClaim"]]),
    # Regex metacharacters in the key must be matched literally.
    ("the c++ code", [["c++", "C plus plus"]]),
    # Dollar signs in the replacement must not be read as a capture reference.
    ("costs money", [["money", "$100"]]),
]

STATS_INPUTS = [
    {"total_words": 0, "total_recordings": 0},
    {"total_words": 1, "total_recordings": 1},
    {"total_words": 12, "total_recordings": 3},
    {"total_words": 1000, "total_recordings": 42},
    {"total_words": 1234567, "total_recordings": 8901},
    # Time-saved thresholds: 40wpm typing vs 150wpm speaking.
    {"total_words": 50, "total_recordings": 2},
    {"total_words": 55, "total_recordings": 2},
    {"total_words": 100, "total_recordings": 5},
    {"total_words": 3272, "total_recordings": 100},
    {"total_words": 3273, "total_recordings": 100},
    {"total_words": 10000, "total_recordings": 300},
]


def main():
    # format_stats / format_time_saved live in menubar.py, which imports rumps
    # and other GUI-only modules at import time. Importing it headless is
    # fragile, so re-derive those two here from the same constants -- they are
    # the reference implementation's arithmetic verbatim (menubar.py:654-691).
    TYPING_WPM, SPEAKING_WPM = 40, 150

    def format_stats(usage):
        words = usage.get("total_words", 0)
        recs = usage.get("total_recordings", 0)
        if words == 0 and recs == 0:
            return "No dictations yet"
        return f"{words:,} words • {recs:,} recordings"

    def format_time_saved(usage):
        words = usage.get("total_words", 0)
        if words <= 0:
            return None
        saved = words * (1 / TYPING_WPM - 1 / SPEAKING_WPM)
        if saved < 1:
            return None
        if saved < 60:
            m = round(saved)
            return f"{m} {'minute' if m == 1 else 'minutes'} saved typing"
        h = round(saved / 60)
        return f"{h} {'hour' if h == 1 else 'hours'} saved typing"

    fixtures = {
        "_generated_by": "swift/Scripts/generate-fixtures.py",
        "_oracle": "daemon.py (clean/join/phonetic), menubar.py:654-691 (stats)",
        "cleanHallucinations": [
            {"input": t, "expected": daemon.clean_hallucinations(t)}
            for t in CLEAN_INPUTS
        ],
        "looksLikeRepetitionLoop": [
            {"input": t, "expected": daemon.looks_like_repetition_loop(t)}
            for t in CLEAN_INPUTS
        ],
        "joinStreamingChunks": [
            {"input": c, "expected": daemon.join_streaming_chunks(c)}
            for c in JOIN_INPUTS
        ],
        "applyPhoneticCorrections": [
            {
                "input": text,
                "corrections": corrections,
                "expected": daemon._apply_phonetic_corrections(
                    text, dict(corrections)
                ),
            }
            for text, corrections in PHONETIC_INPUTS
        ],
        "formatStats": [
            {"input": u, "expected": format_stats(u)} for u in STATS_INPUTS
        ],
        "formatTimeSaved": [
            {"input": u, "expected": format_time_saved(u)} for u in STATS_INPUTS
        ],
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n")

    total = sum(len(v) for v in fixtures.values() if isinstance(v, list))
    print(f"Wrote {total} cases to {OUT.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
