'use strict'

// Optional UI app: the same head unit as the overlay (ui/modModules/stereoLink/headUnit.js),
// for players who prefer placing it in their own apps layout.
angular.module('beamng.apps')
.directive('stereoLinkApp', [function () {
  return {
    restrict: 'E',
    replace: true,
    template: '<div class="bngApp" style="width: 100%; height: 100%;"><sl-head-unit></sl-head-unit></div>',
  }
}])
