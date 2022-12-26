export type Color = string;
export type Clue = { n: number; color: Color };
export type Cell = { color: Color | null };
export type Puzzle = {
  rowClues: Clue[][];
  columnClues: Clue[][];
  state: Cell[][];
};

export function parsePuzzle(xml: string): Puzzle {
  const doc = new DOMParser().parseFromString(xml, "text/xml");
  const puzzleElem = doc.querySelector("puzzle");
  if (!puzzleElem) {
    throw new Error("No puzzle found");
  }
  const rowCluesElem = puzzleElem.querySelector("clues[type='rows']");
  if (!rowCluesElem) {
    throw new Error("No row clues found");
  }
  const columnCluesElem = puzzleElem.querySelector("clues[type='columns']");
  if (!columnCluesElem) {
    throw new Error("No column clues found");
  }
  const rowClues = parseClues(rowCluesElem);
  const columnClues = parseClues(columnCluesElem);
  return {
    rowClues,
    columnClues,
    state: [...Array<undefined>(rowClues.length)].map(() =>
      [...Array<undefined>(columnClues.length)].map(() => ({ color: "white" }))
    ),
  };
}

function parseClues(clues: Element): Clue[][] {
  return [...clues.querySelectorAll("line")].map((line) =>
    [...line.querySelectorAll("count")].map((count) => ({
      n: Number.parseInt(count.textContent ?? ""),
      color: count.getAttribute("color") ?? "black",
    }))
  );
}
