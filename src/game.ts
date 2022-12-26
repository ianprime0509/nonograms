import { LitElement, css, html } from "lit";
import { customElement, query } from "lit/decorators.js";
import "./color-picker.js";
import { ColorPicker } from "./color-picker.js";
import "./grid.js";
import { Grid, CellSelectEvent } from "./grid.js";
import { Color, parsePuzzle } from "./puzzle.js";
import defaultPuzzleXml from "./puzzle.xml?raw";

const defaultPuzzle = parsePuzzle(defaultPuzzleXml);

@customElement("ng-game")
export class Game extends LitElement {
  static override styles = css`
    #container {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      height: 100%;
      width: 100%;
    }

    ng-grid {
      flex: 1 0;
      width: 100%;
    }

    ng-color-picker {
      margin: 1rem 0;
    }
  `;

  @query("ng-grid") private grid!: Grid;
  @query("ng-color-picker") private colorPicker!: ColorPicker;

  override render() {
    const seen = new Set<string>();
    const colorFilter = (color: Color | null): color is Color => {
      if (color === null || seen.has(color)) return false;
      seen.add(color);
      return true;
    };
    const colors = [
      ...defaultPuzzle.columnClues.flat(),
      ...defaultPuzzle.rowClues.flat(),
    ]
      .map(({ color }) => color)
      .filter(colorFilter);
    return html`
      <div id="container">
        <ng-grid
          .puzzle=${defaultPuzzle}
          @cell-select=${this.handleCellSelect}
        ></ng-grid>
        <ng-color-picker .colors=${["white", ...colors]}></ng-color-picker>
      </div>
    `;
  }

  private handleCellSelect(e: CellSelectEvent) {
    this.grid.setColor(e.row, e.column, this.colorPicker.selectedColor);
  }
}

declare global {
  interface HTMLElementTagNameMap {
    "ng-game": Game;
  }
}
