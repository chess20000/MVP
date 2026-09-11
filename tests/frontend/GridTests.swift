import Foundation

@main
struct GridTests {
  static func main() {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { fatalError(message) }
    }

    // Each outer array is a column. Its five entries are the top-to-bottom rows.
    // These are literal expected indices, independent of the selection formula.
    let expectedByColumn = [
      [0, 5, 10, 15, 20],
      [1, 6, 11, 16, 21],
      [2, 7, 12, 17, 22],
      [3, 8, 13, 18, 23],
      [4, 9, 14, 19, 24]
    ]
    var combinations = 0
    for column in 1...5 {
      for row in 1...5 {
        var selection = GridSelection()
        check(selection.column == nil, "A fresh selection must have no column")
        check(selection.digit(column, count: 25) == nil, "The first digit cannot choose a candidate")
        check(selection.column == column, "The first digit must select the column")
        check(selection.digit(row, count: 25) == expectedByColumn[column - 1][row - 1],
              "Wrong cell for column \(column), row \(row)")
        combinations += 1
      }
    }

    func choose(_ shortcut: [Int]) -> Int? {
      check(shortcut.count == 3 && shortcut[0] == 1, "Shortcut must begin with the grid trigger")
      var selection = GridSelection()
      check(selection.digit(shortcut[1], count: 25) == nil, "Column must wait for the row")
      return selection.digit(shortcut[2], count: 25)
    }
    check(choose([1, 3, 4]) == 17, "134 must choose candidate index 17")
    check(choose([1, 5, 5]) == 24, "155 must choose candidate index 24")

    let invalidDigits = [Int.min, -1, 0, 6, 9, Int.max]
    for digit in invalidDigits {
      var selection = GridSelection()
      check(selection.digit(digit, count: 25) == nil, "Invalid first digit selected a candidate")
      check(selection.column == nil, "Invalid first digit changed the column")
      _ = selection.digit(3, count: 25)
      check(selection.digit(digit, count: 25) == nil, "Invalid row selected a candidate")
      check(selection.column == 3, "Invalid row changed the selected column")
      check(selection.digit(4, count: 25) == 17, "Invalid row prevented a later valid choice")
    }

    var shortageChecks = 0
    for available in 0..<25 {
      for column in 1...5 {
        for row in 1...5 {
          var selection = GridSelection()
          _ = selection.digit(column, count: available)
          let expected = expectedByColumn[column - 1][row - 1]
          let result = selection.digit(row, count: available)
          if expected < available {
            check(result == expected, "An available candidate was rejected")
          } else {
            check(result == nil, "A missing candidate was selected")
          }
          shortageChecks += 1
        }
      }
    }

    let grid = GridBackHarness()
    _ = grid.selection.digit(5, count: 25)
    check(grid.selection.column == 5, "Back test did not begin in column 5")
    grid.back()
    check(grid.selection.column == nil, "Back must clear the selected column")
    check(grid.renderCount == 1, "Back must refresh the grid once")
    check(grid.selection.digit(2, count: 25) == nil, "The digit after back must select a new column")
    check(grid.selection.column == 2, "The new column after back is wrong")
    check(grid.selection.digit(3, count: 25) == 11, "New column 2, row 3 must select candidate index 11")

    print("PASS: \(combinations) column/row cells; 134→17; 155→24; \(invalidDigits.count * 2) invalid-digit cases; \(shortageChecks) candidate-shortage cases; back→new column. No UI used.")
  }
}
