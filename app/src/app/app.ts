import { Component } from "@angular/core";
import { RouterOutlet } from "@angular/router";

// One primary outlet, no RouterLinks. Every outlet the Router recognises for
// the measured request comes out of the URL.
@Component({
  selector: "app-root",
  imports: [RouterOutlet],
  template: "<router-outlet />",
})
export class App {}
