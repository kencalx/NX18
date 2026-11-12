# NX conformance fixtures (test data)

The NX archive conformance fixtures of [NXFormat](https://github.com/fab918/nxformat) by fab918, release 1.0.2, commit
`ff6e7d8148cd782af4217ae353b21e428bb6a893` (2026-11-10), MIT licensed (`LICENSE`, copied from the repository root). They are small synthetic `.nx`
files: no game data. dm/tools/tests/test_pack_nx.py reads them with this repository's own reader (scripts/pack_nx.py); no NXFormat code is used or run.
Release 1.0.3 (tag V1.0.3, commit 208b815dc2, 2026-11-11) changed none of them, nor the wire format (0.2 and 0.3).

`fixture_index.json` is upstream's `tests/fixtures/fixture_index.json`, unchanged: each file's size, SHA-256, expected outcome and error code. The test checks
every file against it first. Fetched with `gh api repos/fab918/nxformat/contents/<source path>?ref=ff6e7d81 -H 'Accept: application/vnd.github.raw'`.
Upstream's `tests/fixtures/README.md` describes each case.

| File | Source path | Bytes | Expected |
|---|---|---:|---|
| `minimal_valid.nx` | `tests/fixtures/minimal_valid.nx` | 8,736 | accept |
| `raw_only.nx` | `tests/fixtures/raw_only.nx` | 8,900 | accept |
| `nested_vfs.nx` | `tests/fixtures/nested_vfs.nx` | 9,080 | accept |
| `zstd_single.nx` | `tests/fixtures/zstd_single.nx` | 8,916 | accept |
| `multi_block_file.nx` | `tests/fixtures/multi_block_file.nx` | 74,468 | accept |
| `mixed_raw_zstd.nx` | `tests/fixtures/mixed_raw_zstd.nx` | 271,200 | accept |
| `shared_blocks.nx` | `tests/fixtures/shared_blocks.nx` | 8,996 | accept |
| `shared_with_orphan_block.nx` | `tests/fixtures/shared_with_orphan_block.nx` | 9,048 | accept |
| `corrupted_orphan_block.nx` | `tests/fixtures/corrupted_orphan_block.nx` | 9,048 | reject full verify (block_hash) |
| `shared_snapshots.nx` | `tests/fixtures/shared_snapshots.nx` | 9,044 | accept |
| `deleted_between_versions.nx` | `tests/fixtures/deleted_between_versions.nx` | 9,208 | accept |
| `multiple_programs.nx` | `tests/fixtures/multiple_programs.nx` | 9,240 | accept |
| `metadata_snapshot_tie.nx` | `tests/fixtures/metadata_snapshot_tie.nx` | 9,632 | accept |
| `localized_metadata_icons.nx` | `tests/fixtures/localized_metadata_icons.nx` | 9,072 | accept |
| `switch2_localized_icons.nx` | `tests/fixtures/switch2_localized_icons.nx` | 9,008 | accept |
| `jpeg_icon.nx` | `tests/fixtures/jpeg_icon.nx` | 9,120 | accept |
| `same_application_id_cross_platform.nx` | `tests/fixtures/same_application_id_cross_platform.nx` | 8,960 | accept |
| `dlc_without_program.nx` | `tests/fixtures/dlc_without_program.nx` | 8,880 | accept |
| `dlc_with_program.nx` | `tests/fixtures/dlc_with_program.nx` | 8,864 | accept |
| `distinct_dlc_same_tree.nx` | `tests/fixtures/distinct_dlc_same_tree.nx` | 8,976 | accept |
| `dlc_only_application.nx` | `tests/fixtures/dlc_only_application.nx` | 8,640 | accept |
| `empty_files.nx` | `tests/fixtures/empty_files.nx` | 8,833 | accept |
| `corrupted_manifest.nx` | `tests/fixtures/corrupted_manifest.nx` | 8,900 | reject (manifest_hash) |
| `corrupted_integrity_table.nx` | `tests/fixtures/corrupted_integrity_table.nx` | 8,900 | reject (index_hash) |
| `corrupted_hot_index.nx` | `tests/fixtures/corrupted_hot_index.nx` | 8,900 | reject (index_hash) |
| `corrupted_index_sha256.nx` | `tests/fixtures/corrupted_index_sha256.nx` | 8,900 | reject (index_hash) |
| `corrupted_block_payload.nx` | `tests/fixtures/corrupted_block_payload.nx` | 8,900 | reject full verify (block_hash) |
| `invalid_metadata_snapshot.nx` | `tests/fixtures/invalid_metadata_snapshot.nx` | 8,736 | reject (catalog) |
| `invalid_empty_metadata_source.nx` | `tests/fixtures/invalid_empty_metadata_source.nx` | 8,704 | reject (catalog) |
| `invalid_history_media_type.nx` | `tests/fixtures/invalid_history_media_type.nx` | 9,632 | reject (catalog) |
| `invalid_present_empty_title.nx` | `tests/fixtures/invalid_present_empty_title.nx` | 8,736 | reject (string) |
| `invalid_language_subtag.nx` | `tests/fixtures/invalid_language_subtag.nx` | 9,072 | reject (catalog) |
| `invalid_shared_media_types.nx` | `tests/fixtures/invalid_shared_media_types.nx` | 9,072 | reject (catalog) |
| `duplicate_snapshot_identity.nx` | `tests/fixtures/duplicate_snapshot_identity.nx` | 8,976 | reject (catalog) |
| `invalid_snapshot_program.nx` | `tests/fixtures/invalid_snapshot_program.nx` | 8,736 | reject (catalog) |
| `invalid_build_id_flag.nx` | `tests/fixtures/invalid_build_id_flag.nx` | 8,736 | reject (catalog) |
| `invalid_program_application.nx` | `tests/fixtures/invalid_program_application.nx` | 9,240 | reject (catalog) |
| `duplicate_application_key.nx` | `tests/fixtures/duplicate_application_key.nx` | 8,960 | reject (catalog) |
| `invalid_metadata_snapshot_owner.nx` | `tests/fixtures/invalid_metadata_snapshot_owner.nx` | 8,960 | reject (catalog) |
| `invalid_program_snapshot_range.nx` | `tests/fixtures/invalid_program_snapshot_range.nx` | 8,960 | reject (catalog) |
| `invalid_offsets.nx` | `tests/fixtures/invalid_offsets.nx` | 8,736 | reject (bounds) |
| `truncated_archive.nx` | `tests/fixtures/truncated_archive.nx` | 8,735 | reject (length) |
| `invalid_path.nx` | `tests/fixtures/invalid_path.nx` | 8,900 | reject (path) |
| `cyclic_directory.nx` | `tests/fixtures/cyclic_directory.nx` | 9,080 | reject (manifest) |
| `repeated_directory.nx` | `tests/fixtures/repeated_directory.nx` | 9,076 | reject (manifest) |
| `repeated_file.nx` | `tests/fixtures/repeated_file.nx` | 8,996 | reject (manifest) |
| `unknown_mandatory_feature.nx` | `tests/fixtures/unknown_mandatory_feature.nx` | 8,736 | reject (feature) |
| `appended_generation.nx` | `tests/fixtures/appended_generation.nx` | 10,000 | accept |
| `appended_generation_2.nx` | `tests/fixtures/appended_generation_2.nx` | 10,928 | accept |
| `interrupted_commit.nx` | `tests/fixtures/interrupted_commit.nx` | 10,100 | accept |
| `damaged_slot_a.nx` | `tests/fixtures/damaged_slot_a.nx` | 8,900 | accept |
| `lost_header_page_0.nx` | `tests/fixtures/lost_header_page_0.nx` | 10,928 | accept |
| `lost_header_page_1.nx` | `tests/fixtures/lost_header_page_1.nx` | 10,928 | accept |
| `bad_header_page_padding_1.nx` | `tests/fixtures/bad_header_page_padding_1.nx` | 8,900 | accept |
| `bad_header_page_padding_2.nx` | `tests/fixtures/bad_header_page_padding_2.nx` | 8,900 | reject (unsupported) |
| `legacy_shared_header_page.nx` | `tests/fixtures/legacy_shared_header_page.nx` | 8,736 | reject (unsupported) |
| `truncated_header_area.nx` | `tests/fixtures/truncated_header_area.nx` | 8,191 | reject (length) |
| `unknown_optional_header_feature.nx` | `tests/fixtures/unknown_optional_header_feature.nx` | 8,900 | reject (feature) |
| `max_generation.nx` | `tests/fixtures/max_generation.nx` | 9,044 | accept |
| `slot_generation_conflict.nx` | `tests/fixtures/slot_generation_conflict.nx` | 8,900 | reject (format) |
| `damaged_both_slots.nx` | `tests/fixtures/damaged_both_slots.nx` | 8,900 | reject (unsupported) |
| `fixture_index.json` | `tests/fixtures/fixture_index.json` | | the index above |
| `LICENSE` | `LICENSE` | | MIT, (c) 2026 fab918 |
