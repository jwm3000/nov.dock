#include "geometry.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace AeroSnap;
    const Rect screen{-1920, -200, 1920, 1080};
    assert(dockZoneAt({-1900, -200}, screen, 12) == Zone::Maximize);
    assert(dockZoneAt({-1920, -200}, screen, 12) == Zone::Maximize);
    assert(dockZoneAt({-1, -200}, screen, 12) == Zone::Maximize);
    assert(dockZoneAt({-1915, 300}, screen, 12) == Zone::LeftHalf);
    assert(dockZoneAt({-5, 300}, screen, 12) == Zone::RightHalf);
    assert(dockZoneAt({-960, 880}, screen, 12) == Zone::None);
    assert(dockZoneAt({-960, 300}, screen, 12) == Zone::None);
    assert(dockZoneAt({12, 300}, screen, 12) == Zone::None);
    const Rect scaled{0, 0, 1706.6667, 960};
    assert(dockZoneAt({1704, 480}, scaled, 12) == Zone::RightHalf);
    const auto left = rectForZone(scaled, Zone::LeftHalf, 0, 0, 2);
    const auto right = rectForZone(scaled, Zone::RightHalf, 0, 0, 2);
    assert(left && right && left->w == right->w && left->x + left->w == right->x);
    // With a 30 px bar on top, the maximize zone reaches down to its lower
    // edge plus the threshold, and still covers the bar itself.
    const Rect laptop{0, 0, 1440, 900};
    assert(dockZoneAt({700, 40}, laptop, 12, 30) == Zone::Maximize);
    assert(dockZoneAt({700, 42}, laptop, 12, 30) == Zone::Maximize);
    assert(dockZoneAt({700, 15}, laptop, 12, 30) == Zone::Maximize);
    assert(dockZoneAt({700, 43}, laptop, 12, 30) == Zone::None);
    assert(dockZoneAt({700, 40}, laptop, 12) == Zone::None);
    std::cout << "Floating Dock edge geometry passed\n";
}
