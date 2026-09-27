import { Component } from "@angular/core";
import { RouterOutlet } from "@angular/router";

// An ordinary page with a named outlet beside its content.
@Component({
  selector: "app-dashboard",
  imports: [RouterOutlet],
  template: '<main>Dashboard</main><router-outlet name="detail" />',
})
export class Dashboard {}

// What the named outlet holds. Trivial on purpose: the cost is paid before it
// renders.
@Component({
  selector: "app-detail",
  imports: [RouterOutlet],
  template: '<aside id="detail">Detail</aside><router-outlet name="aside" />',
})
export class DetailPanel {}

@Component({
  selector: "app-aside",
  imports: [RouterOutlet],
  template: "<span>Aside</span><router-outlet />",
})
export class Aside {}

// The 404 page. It exists so the catch-all route does.
@Component({
  selector: "app-not-found",
  template: '<main id="not-found">Not found</main>',
})
export class NotFound {}

// The resources shape, copied from the lab that measured it.
@Component({
  selector: "app-shell",
  imports: [RouterOutlet],
  template: '<main><router-outlet /></main><router-outlet name="side" />',
})
export class Shell {}

@Component({
  selector: "app-report",
  template: '<p>Report</p>',
})
export class Report {}

@Component({ selector: "app-panel", template: '<p>Panel</p>' })
export class Panel {}
