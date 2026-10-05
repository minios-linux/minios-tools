@test "RAM container copying and independent thaw guard" {
    run python3 "$BATS_TEST_DIRNAME/ram_save_case.py"
    [ "$status" -eq 0 ]
}
