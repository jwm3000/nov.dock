#define WLR_USE_UNSTABLE

#include "geometry.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/animation/WorkspaceAnimationController.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/shared/complex/ComplexDataTypes.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/ColorValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/space/Space.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <linux/input-event-codes.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace {

    using AeroSnap::Zone;

    using PreviewClock = std::chrono::steady_clock;

    HANDLE pluginHandle = nullptr;

    struct SConfigValues {
        SP<Config::Values::CBoolValue>   enabled;
        SP<Config::Values::CBoolValue>   floatingModeOnly;
        SP<Config::Values::CStringValue> columns;
        SP<Config::Values::CIntValue>    edgeThreshold;
        SP<Config::Values::CFloatValue>  cornerRatio;
        SP<Config::Values::CColorValue>  previewColor;
        SP<Config::Values::CColorValue>  previewBorderColor;
        SP<Config::Values::CIntValue>    previewBorderSize;
        SP<Config::Values::CIntValue>    previewRounding;
        SP<Config::Values::CBoolValue>   previewBlur;
        SP<Config::Values::CIntValue>    previewAnimationDuration;
        SP<Config::Values::CStringValue> dockEdge;
        SP<Config::Values::CIntValue>    dockReserve;
    };

    struct SPlacement {
        SP<Layout::ITarget> target;
        Zone                zone = Zone::None;
        CBox                previewBox;
        CBox                clientBox;
    };

    struct SPreview {
        PHLMONITORREF             monitor;
        CBox                      fromBox;
        CBox                      targetBox;
        PreviewClock::time_point  startedAt;
        std::chrono::milliseconds duration{0};
        float                     fromOpacity   = 0.F;
        float                     targetOpacity = 1.F;
    };

    struct SPreviewFrame {
        CBox  box;
        float opacity = 0.F;
        bool  settled = true;
    };

    struct SSnapRecord {
        PHLWINDOWREF window;
        CBox         restoreBox;
        CBox         snappedBox;
        Zone         zone = Zone::None;
    };

    struct SDragState {
        SP<Layout::ITarget>       target;
        CBox                      startBox;
        std::optional<SPlacement> candidate;
        bool                      modeActive = false;
        bool                      leftQuarters = true;
        bool                      rightQuarters = true;
    };

    struct SPluginState {
        SConfigValues             config;
        std::optional<SPreview>   preview;
        std::optional<SDragState> drag;
        std::vector<SSnapRecord>  records;
        UP<SEventLoopDoLaterLock> pendingApply;
        UP<SEventLoopDoLaterLock> pendingLuaRegistration;
        CHyprSignalListener       mouseMoveListener;
        CHyprSignalListener       mouseButtonListener;
        CHyprSignalListener       renderListener;
        CHyprSignalListener       windowDestroyListener;
        CHyprSignalListener       windowFloatingListener;
        CHyprSignalListener       windowActiveListener;
        bool                      swallowRelease = false;
    };

    UP<SPluginState> state;

    SDragState makeDragState(const SP<Layout::ITarget>& target, const CBox& startBox, const bool modeActive) {
        return {
            target,
            startBox,
            std::nullopt,
            modeActive,
            false,
            false,
        };
    }

    AeroSnap::Rect   toRect(const CBox& box) {
        return {box.x, box.y, box.w, box.h};
    }

    CBox toBox(const AeroSnap::Rect rect) {
        CBox box{rect.x, rect.y, rect.w, rect.h};
        box.round();
        return box;
    }

    bool sameBox(const CBox& lhs, const CBox& rhs) {
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.w == rhs.w && lhs.h == rhs.h;
    }

    void damagePreviewBox(const CBox& box) {
        constexpr double padding = 12;
        g_pHyprRenderer->damageBox({box.x - padding, box.y - padding, box.w + padding * 2, box.h + padding * 2});
    }

    SPreviewFrame previewFrame(const SPreview& preview, const PreviewClock::time_point now) {
        const double elapsed  = std::chrono::duration<double, std::milli>(now - preview.startedAt).count();
        const double duration = static_cast<double>(preview.duration.count());
        const double progress = duration <= 0.0 ? 1.0 : std::clamp(elapsed / duration, 0.0, 1.0);
        const double eased    = AeroSnap::outQuart(progress);

        return {
            toBox(AeroSnap::interpolateRect(toRect(preview.fromBox), toRect(preview.targetBox), eased)),
            static_cast<float>(preview.fromOpacity + (preview.targetOpacity - preview.fromOpacity) * eased),
            progress >= 1.0,
        };
    }

    int previewMilliseconds() {
        static auto animations = CConfigValue<Config::INTEGER>("animations:enabled");
        return *animations ? std::clamp(static_cast<int>(state->config.previewAnimationDuration->value()), 0, 250) : 0;
    }

    std::chrono::milliseconds previewDuration(const CBox& fromBox, const CBox& targetBox, const PHLMONITOR& monitor, const double opacityDistance = 0.0) {
        const int configured = previewMilliseconds();
        if (configured == 0 || !monitor)
            return std::chrono::milliseconds{0};

        const CBox   monitorBox  = monitor->logicalBox();
        const double reference   = std::max(1.0, monitorBox.w / 3.0);
        const double boxDistance = std::max({
            std::abs(targetBox.x - fromBox.x),
            std::abs(targetBox.y - fromBox.y),
            std::abs(targetBox.w - fromBox.w),
            std::abs(targetBox.h - fromBox.h),
        });
        const double distance    = std::clamp(std::max(boxDistance / reference, opacityDistance), 0.1, 1.0);
        return std::chrono::milliseconds{std::max(1, static_cast<int>(std::round(configured * distance)))};
    }

    void clearPreview() {
        if (!state || !state->preview)
            return;

        if (state->preview->targetOpacity <= 0.F)
            return;

        const auto now        = PreviewClock::now();
        const auto current    = previewFrame(*state->preview, now);
        const CBox target     = toBox(AeroSnap::scaleRectFromCenter(toRect(current.box), 0.985));
        const auto monitor    = state->preview->monitor.lock();
        const int  configured = previewMilliseconds();
        const auto duration =
            configured == 0 ? std::chrono::milliseconds{0} : std::chrono::milliseconds{std::max(1, static_cast<int>(std::round(configured * 0.625 * current.opacity)))};

        damagePreviewBox(current.box);
        damagePreviewBox(target);
        state->preview = SPreview{monitor, current.box, target, now, duration, current.opacity, 0.F};
    }

    void setPreview(const PHLMONITOR& monitor, const CBox& box) {
        if (state->preview && state->preview->monitor.lock() == monitor && sameBox(state->preview->targetBox, box) && state->preview->targetOpacity >= 1.F)
            return;

        const auto now = PreviewClock::now();
        if (state->preview && state->preview->monitor.lock() == monitor) {
            const auto current  = previewFrame(*state->preview, now);
            const auto duration = previewDuration(current.box, box, monitor, 1.0 - current.opacity);
            damagePreviewBox(current.box);
            damagePreviewBox(box);
            state->preview = SPreview{monitor, current.box, box, now, duration, current.opacity, 1.F};
            return;
        }

        if (state->preview) {
            const auto current = previewFrame(*state->preview, now);
            damagePreviewBox(current.box);
            damagePreviewBox(state->preview->targetBox);
        }

        const CBox from       = toBox(AeroSnap::scaleRectFromCenter(toRect(box), 0.96));
        const int  configured = previewMilliseconds();
        state->preview        = SPreview{monitor, from, box, now, std::chrono::milliseconds{configured}, 0.F, 1.F};
        damagePreviewBox(from);
        damagePreviewBox(box);
    }

    void pruneRecords() {
        std::erase_if(state->records, [](const auto& record) { return !record.window.valid() || record.window.expired(); });
    }

    SSnapRecord* recordFor(const PHLWINDOW& window) {
        pruneRecords();
        const auto found = std::ranges::find_if(state->records, [&](const auto& record) { return record.window.lock() == window; });
        return found == state->records.end() ? nullptr : &*found;
    }

    void rememberSnap(const PHLWINDOW& window, const CBox& restoreBox, const CBox& snappedBox, const Zone zone) {
        if (const auto record = recordFor(window)) {
            record->snappedBox = snappedBox;
            record->zone       = zone;
            return;
        }

        state->records.push_back({window, restoreBox, snappedBox, zone});
    }

    void forgetRestoreBox(const PHLWINDOW& window) {
        std::erase_if(state->records, [&](const auto& record) { return record.window.lock() == window; });
    }

    void restoreTrackedWindows() {
        auto records = std::move(state->records);
        state->records.clear();

        for (const auto& record : records) {
            const auto window = record.window.lock();
            if (!Desktop::View::validMapped(window) || !window->m_target || !window->m_target->floating())
                continue;

            const auto target = window->m_target;
            if (record.zone == Zone::Maximize) {
                if (!Fullscreen::controller()->isFullscreen(window, Fullscreen::FSMODE_MAXIMIZED))
                    continue;
                Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE);
            } else if (!sameBox(target->position(), record.snappedBox))
                continue;

            g_layoutManager->setTargetGeom(record.restoreBox, target);
            target->warpPositionSize();
            target->damageEntire();
        }
    }

    SSnapRecord* currentSnapRecord(const SP<Layout::ITarget>& target, const bool allowMoved) {
        if (!target || !Desktop::View::validMapped(target->window()))
            return nullptr;

        const auto window = target->window();
        const auto record = recordFor(window);
        if (!record)
            return nullptr;

        bool matches = false;
        if (record->zone == Zone::Maximize) {
            matches = Fullscreen::controller()->isFullscreen(window, Fullscreen::FSMODE_MAXIMIZED);
        } else {
            const CBox current = target->position();
            matches            = current.w == record->snappedBox.w && current.h == record->snappedBox.h;
            if (matches && !allowMoved)
                matches = current.x == record->snappedBox.x && current.y == record->snappedBox.y;
        }

        if (matches)
            return record;

        forgetRestoreBox(window);
        return nullptr;
    }

    bool floatingModeActive() {
        if (!state || !state->config.enabled->value())
            return false;
        if (!state->config.floatingModeOnly->value())
            return true;

        const auto focus = Desktop::focusState();
        const auto window = focus ? focus->window() : nullptr;
        return Desktop::View::validMapped(window) && window->m_ruleApplicator &&
            window->m_ruleApplicator->m_tagKeeper.isTagged("omarchy-floating-workspace");
    }

    PHLWORKSPACE activeWorkspace(const PHLMONITOR& monitor) {
        return monitor->m_activeSpecialWorkspace ? monitor->m_activeSpecialWorkspace : monitor->m_activeWorkspace;
    }

    std::optional<SPlacement> placementFor(const SP<Layout::ITarget>& target, const PHLMONITOR& monitor, const Zone zone) {
        if (!target || !target->floating() || !Desktop::View::validMapped(target->window()) || !monitor || zone == Zone::None)
            return std::nullopt;

        const auto workspace = activeWorkspace(monitor);
        if (!workspace || !workspace->m_space)
            return std::nullopt;

        const bool   gapsEnabled       = false;
        // The floating work area keeps reserved regions (for example the bar)
        // but does not inset the monitor by gaps_out. Maximize fills it, like
        // Hyprland's own maximize; the halves also leave the dock visible.
        const CBox   floatingArea      = workspace->m_space->workArea(true);
        const CBox   workArea          = zone == Zone::Maximize ? floatingArea
                                                                : toBox(AeroSnap::insetForDock(toRect(floatingArea), state->config.dockEdge->value(),
                                                                                               state->config.dockReserve->value()));
        const auto   configuredColumns = state->config.columns->value();
        const int    columns           = AeroSnap::columnsForMonitor(toRect(monitor->logicalBox()), configuredColumns);

        static auto  gapsInValue   = CConfigValue<Config::IComplexConfigValue>("general:gaps_in");
        const auto*  gapsIn        = sc<Config::CCssGapData*>(gapsInValue.ptr());
        const double horizontalGap = gapsEnabled ? gapsIn->m_left + gapsIn->m_right : 0.0;
        const double verticalGap   = gapsEnabled ? gapsIn->m_top + gapsIn->m_bottom : 0.0;
        const auto   zoneRect      = AeroSnap::rectForZone(toRect(workArea), zone, horizontalGap, verticalGap, columns);
        if (!zoneRect)
            return std::nullopt;

        const CBox requestedOuter = toBox(*zoneRect);
        if (zone == Zone::Maximize)
            return SPlacement{target, zone, requestedOuter, {}};

        const auto     window  = target->window();
        const auto     extents = window->getWindowExtentsUnified(Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
        const Vector2D availableSize{
            requestedOuter.w - extents.topLeft.x - extents.bottomRight.x,
            requestedOuter.h - extents.topLeft.y - extents.bottomRight.y,
        };
        const Vector2D minSize         = target->minSize().value_or(Vector2D{1, 1});
        const Vector2D reportedMaxSize = target->maxSize().value_or(Math::VECTOR2D_MAX);
        const Vector2D maxSize{
            std::max(minSize.x, reportedMaxSize.x),
            std::max(minSize.y, reportedMaxSize.y),
        };

        if (availableSize.x < minSize.x || availableSize.y < minSize.y)
            return std::nullopt;

        const Vector2D clientSize{
            std::clamp(availableSize.x, minSize.x, maxSize.x),
            std::clamp(availableSize.y, minSize.y, maxSize.y),
        };
        const Vector2D actualOuterSize{
            clientSize.x + extents.topLeft.x + extents.bottomRight.x,
            clientSize.y + extents.topLeft.y + extents.bottomRight.y,
        };
        CBox actualOuter{
            requestedOuter.x + (requestedOuter.w - actualOuterSize.x) / 2.0,
            requestedOuter.y + (requestedOuter.h - actualOuterSize.y) / 2.0,
            actualOuterSize.x,
            actualOuterSize.y,
        };
        CBox clientBox{
            actualOuter.x + extents.topLeft.x,
            actualOuter.y + extents.topLeft.y,
            clientSize.x,
            clientSize.y,
        };
        actualOuter.round();
        clientBox.round();

        return SPlacement{target, zone, actualOuter, clientBox};
    }

    void applyPlacement(const SPlacement& placement, const CBox& restoreBox) {
        const auto target = placement.target;
        if (!target || !target->floating() || !Desktop::View::validMapped(target->window()))
            return;

        const auto window = target->window();

        if (placement.zone == Zone::Maximize) {
            Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_MAXIMIZED);
            rememberSnap(window, restoreBox, placement.previewBox, placement.zone);
            return;
        }

        if (Fullscreen::controller()->isFullscreen(window))
            Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE);

        g_layoutManager->setTargetGeom(placement.clientBox, target);
        target->damageEntire();
        rememberSnap(window, restoreBox, placement.clientBox, placement.zone);
    }

    PHLWINDOW focusedWindow() {
        const auto focus = Desktop::focusState();
        return focus ? focus->window() : nullptr;
    }

    SDispatchResult dispatchKeyboardSnap(std::string direction) {
        if (!floatingModeActive())
            return {.passEvent = true, .success = false, .error = "Floating Mode is not active"};

        const auto window = focusedWindow();
        if (!Desktop::View::validMapped(window) || !window->m_target || !window->m_target->floating())
            return {.success = false, .error = "No focused floating window"};

        const auto target = window->m_target;
        if (direction == "restore") {
            const auto record = recordFor(window);
            if (!record)
                return {};

            const CBox restoreBox = record->restoreBox;
            if (Fullscreen::controller()->isFullscreen(window))
                Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE);
            forgetRestoreBox(window);
            g_layoutManager->setTargetGeom(restoreBox, target);
            target->warpPositionSize();
            target->damageEntire();
            return {};
        }

        Zone zone = Zone::None;
        if (direction == "left")
            zone = Zone::LeftHalf;
        else if (direction == "right")
            zone = Zone::RightHalf;
        else if (direction == "maximize")
            zone = Zone::Maximize;
        else
            return {.success = false, .error = "Expected left, right, maximize, or restore"};

        // Fullscreen/maximized windows have different decoration extents.
        // Leave that state before calculating the half so the client height
        // is based on the restored titlebar and borders.
        if (Fullscreen::controller()->isFullscreen(window))
            Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE);

        const auto monitor   = window->m_monitor.lock();
        const auto placement = placementFor(target, monitor, zone);
        if (!placement)
            return {.success = false, .error = "Cannot place the focused window"};

        // Repeated keyboard snaps retain the geometry from before the first
        // snap, making Restore deterministic across every direction change.
        const auto record     = recordFor(window);
        const CBox restoreBox = record ? record->restoreBox : target->position();
        applyPlacement(*placement, restoreBox);
        return {};
    }

    int luaSnapLeft(lua_State*) {
        dispatchKeyboardSnap("left");
        return 0;
    }

    int luaSnapRight(lua_State*) {
        dispatchKeyboardSnap("right");
        return 0;
    }

    int luaSnapMaximize(lua_State*) {
        dispatchKeyboardSnap("maximize");
        return 0;
    }

    int luaSnapRestore(lua_State*) {
        dispatchKeyboardSnap("restore");
        return 0;
    }

    bool restoreSnappedDrag(const SP<Layout::ITarget>& target, const Vector2D cursor, Event::SCallbackInfo& info) {
        const auto window = target->window();
        const auto record = currentSnapRecord(target, true);
        if (!record)
            return false;

        const CBox restoreBox = record->restoreBox;
        const auto extents    = window->getWindowExtentsUnified(Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS);
        const CBox current    = target->position();
        const CBox currentOuter{
            current.x - extents.topLeft.x,
            current.y - extents.topLeft.y,
            current.w + extents.topLeft.x + extents.bottomRight.x,
            current.h + extents.topLeft.y + extents.bottomRight.y,
        };
        const double   anchorX = std::clamp((cursor.x - currentOuter.x) / std::max(1.0, currentOuter.w), 0.08, 0.92);
        const double   anchorY = std::clamp(cursor.y - currentOuter.y, 0.0, std::max(0.0, currentOuter.h * 0.25));
        const Vector2D restoredOuterSize{
            restoreBox.w + extents.topLeft.x + extents.bottomRight.x,
            restoreBox.h + extents.topLeft.y + extents.bottomRight.y,
        };
        CBox anchoredRestore{
            cursor.x - restoredOuterSize.x * anchorX + extents.topLeft.x,
            cursor.y - anchorY + extents.topLeft.y,
            restoreBox.w,
            restoreBox.h,
        };
        anchoredRestore.round();

        if (Fullscreen::controller()->isFullscreen(window))
            Fullscreen::controller()->setFullscreenMode(window, Fullscreen::FSMODE_NONE);
        forgetRestoreBox(window);
        clearPreview();
        g_layoutManager->endDragTarget();
        g_layoutManager->setTargetGeom(anchoredRestore, target);
        target->warpPositionSize();
        g_layoutManager->beginDragTarget(target, MBIND_MOVE);
        // Rebuild the drag after detaching a previously snapped window without
        // falling back to SDragState's quarter-zone defaults.
        state->drag    = makeDragState(target, anchoredRestore, true);
        info.cancelled = true;
        return true;
    }

    void resetDrag() {
        clearPreview();
        state->drag.reset();
    }

    void onMouseMove(const Vector2D cursor, Event::SCallbackInfo& info) {
        if (!state)
            return;

        const auto& controller = g_layoutManager->dragController();
        const auto  target     = controller->target();
        if (target && controller->mode() != MBIND_MOVE && controller->dragThresholdReached() && Desktop::View::validMapped(target->window()))
            forgetRestoreBox(target->window());
        if (!target || controller->mode() != MBIND_MOVE || controller->draggingTiled() || !target->floating() || !Desktop::View::validMapped(target->window())) {
            resetDrag();
            return;
        }
        if (!state->drag || state->drag->target != target)
            state->drag = makeDragState(target, target->position(), state->config.enabled->value() &&
                target->window()->m_ruleApplicator && target->window()->m_ruleApplicator->m_tagKeeper.isTagged("omarchy-floating-workspace"));

        if (!state->drag->modeActive)
            return;

        if (!controller->dragThresholdReached())
            currentSnapRecord(target, false);

        if (controller->dragThresholdReached() && restoreSnappedDrag(target, cursor, info))
            return;

        if (!controller->dragThresholdReached()) {
            clearPreview();
            state->drag->candidate.reset();
            return;
        }

        const auto monitor = State::monitorState()->query().vec(cursor).run();
        if (!monitor) {
            clearPreview();
            state->drag->candidate.reset();
            return;
        }

        const auto monitorBox        = monitor->logicalBox();
        const auto zone = AeroSnap::dockZoneAt({cursor.x, cursor.y}, toRect(monitorBox), state->config.edgeThreshold->value());
        const auto placement = placementFor(target, monitor, zone);
        if (!placement) {
            clearPreview();
            state->drag->candidate.reset();
            return;
        }

        state->drag->candidate = placement;
        setPreview(monitor, placement->previewBox);
    }

    // Whether the dock takes pointer input at this point: its layer surface
    // is large, but its input region is only the strip of icons and menus.
    bool dockAcceptsPointerAt(const Vector2D cursor) {
        for (const auto& layer : Desktop::layerState()->layers()) {
            if (!layer || !layer->m_mapped || layer->m_namespace != "omarchy-dock")
                continue;
            const CBox& geometry = layer->m_geometry;
            if (!geometry.containsPoint(cursor))
                continue;
            const auto surface = layer->wlSurface() ? layer->wlSurface()->resource() : nullptr;
            if (!surface)
                continue;
            if (surface->m_current.effectiveInputRegion().containsPoint(cursor - geometry.pos()))
                return true;
        }
        return false;
    }

    void spawnDetached(std::vector<std::string> args) {
        const pid_t child = fork();
        if (child < 0)
            return;
        if (child == 0) {
            setsid();
            if (fork() != 0)
                _exit(0);
            std::vector<char*> argv;
            for (auto& arg : args)
                argv.push_back(arg.data());
            argv.push_back(nullptr);
            execvp(argv[0], argv.data());
            _exit(127);
        }
        waitpid(child, nullptr, 0);
    }

    // Super+click is Hyprland's window drag, and the dock has no keyboard
    // focus to see Super anyway, so a Super+click on the dock is handed to
    // the dock itself: it opens a new window of the app under the pointer.
    bool forwardSuperClickToDock(const IPointer::SButtonEvent& event, Event::SCallbackInfo& info) {
        if (event.button != BTN_LEFT)
            return false;
        if (event.state == WL_POINTER_BUTTON_STATE_RELEASED) {
            if (!state->swallowRelease)
                return false;
            state->swallowRelease = false;
            info.cancelled        = true;
            return true;
        }
        if (!(g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_META))
            return false;
        const Vector2D cursor = g_pInputManager->getMouseCoordsInternal();
        if (!dockAcceptsPointerAt(cursor))
            return false;
        state->swallowRelease = true;
        info.cancelled        = true;
        spawnDetached({"omarchy-shell", "-q", "omarchy.dock", "superClick", std::to_string(static_cast<int>(std::round(cursor.x))),
                       std::to_string(static_cast<int>(std::round(cursor.y)))});
        return true;
    }

    // Hyprland draws a window focused over a maximized one above it, and keeps
    // doing so after focus returns (Alt+Tab, a click): the maximized window has
    // focus but stays hidden behind it. On a floating workspace, focusing the
    // maximized window sends the others below it, in their own order.
    void onWindowActive(const PHLWINDOW& window) {
        if (!state || !Desktop::View::validMapped(window) || !window->m_ruleApplicator ||
            !window->m_ruleApplicator->m_tagKeeper.isTagged("omarchy-floating-workspace"))
            return;
        // An earlier build switched this off for windows under a maximized
        // one; give it back as they are used.
        window->m_allowedOverFullscreen = true;
        const auto workspace = window->m_workspace;
        if (!workspace || !Fullscreen::controller()->isFullscreen(window, Fullscreen::FSMODE_MAXIMIZED))
            return;
        // The list runs bottom to top; sending the topmost down first keeps
        // the others' order among themselves.
        const auto windows = Desktop::windowState()->windows();
        bool       changed = false;
        for (auto it = windows.rbegin(); it != windows.rend(); ++it) {
            const auto& other = *it;
            if (!other || other == window || !other->m_isMapped || other->m_workspace != workspace || other->m_pinned)
                continue;
            Desktop::windowState()->lower(other);
            changed = true;
        }
        if (changed) {
            if (const auto monitor = window->m_monitor.lock())
                g_pHyprRenderer->damageMonitor(monitor);
        }
    }

    void onMouseButton(const IPointer::SButtonEvent event, Event::SCallbackInfo& info) {
        if (!state || event.button != BTN_LEFT)
            return;
        if (forwardSuperClickToDock(event, info))
            return;

        if (!state || event.state != WL_POINTER_BUTTON_STATE_RELEASED || event.button != BTN_LEFT || !state->drag)
            return;

        const auto drag = *state->drag;
        resetDrag();
        if (!drag.candidate)
            return;

        const auto placement = *drag.candidate;
        state->pendingApply  = g_pEventLoopManager->doLaterLock([placement, restoreBox = drag.startBox] {
            if (!state || !state->config.enabled->value() || !placement.target || !Desktop::View::validMapped(placement.target->window()) || !placement.target->window()->m_ruleApplicator->m_tagKeeper.isTagged("omarchy-floating-workspace"))
                return;

            if (g_layoutManager->dragController()->target() == placement.target)
                g_layoutManager->endDragTarget();
            applyPlacement(placement, restoreBox);
        });
    }

    // A fullscreen window on a special workspace (the screensaver opens one
    // per monitor) should fade the monitor's top layers, the bar and the dock,
    // out of sight. Hyprland 0.56 re-derives that fade from the monitor's
    // regular workspace on focus and workspace changes elsewhere, so with two
    // monitors the laptop's bar comes back over its screensaver. Each frame, a
    // monitor showing a special workspace with a real fullscreen window gets
    // the fade put back, once, whenever a top layer has drifted back in.
    void keepTopLayersUnderSpecialFullscreen(const PHLMONITOR& monitor) {
        if (!monitor)
            return;
        const auto special = monitor->m_activeSpecialWorkspace;
        if (!special)
            return;
        const auto fullscreen = Fullscreen::controller()->getFullscreenWindow(special, true);
        if (!fullscreen || !Fullscreen::controller()->isFullscreen(fullscreen, Fullscreen::FSMODE_FULLSCREEN))
            return;
        bool drifted = false;
        for (const auto& layer : Desktop::layerState()->layers()) {
            if (!layer || !layer->m_mapped || layer->m_layer != 2 /* top */ || layer->m_monitor.lock() != monitor)
                continue;
            if (layer->m_aboveFullscreen || layer->alpha()[Desktop::View::LS_ALPHA_FADE]->goal() > 0.F) {
                layer->m_aboveFullscreen = false;
                drifted                  = true;
            }
        }
        if (drifted)
            Animation::Workspace::setFullscreenFadeAnimation(special, Animation::Workspace::ANIMATION_TYPE_IN);
    }

    void onRenderStage(const eRenderStage stageValue) {
        if (!state)
            return;

        if (stageValue == RENDER_BEGIN) {
            keepTopLayersUnderSpecialFullscreen(g_pHyprRenderer->renderData().pMonitor.lock());
            return;
        }

        if (stageValue != RENDER_POST_WINDOWS || !state->preview)
            return;

        const auto monitor = g_pHyprRenderer->renderData().pMonitor.lock();
        if (!monitor || state->preview->monitor.lock() != monitor)
            return;

        const auto frame = previewFrame(*state->preview, PreviewClock::now());
        if (frame.settled && state->preview->targetOpacity <= 0.F) {
            damagePreviewBox(frame.box);
            state->preview.reset();
            return;
        }

        if (!frame.settled) {
            damagePreviewBox(frame.box);
            damagePreviewBox(state->preview->targetBox);
        }

        CBox outer = frame.box;
        outer.translate(-monitor->m_position).scale(monitor->m_scale).round();

        const float opacity  = std::clamp(frame.opacity, 0.F, 1.F);
        const int   border   = std::max(0, static_cast<int>(std::round(state->config.previewBorderSize->value() * monitor->m_scale)));
        const int   rounding = std::max(0, static_cast<int>(std::round(state->config.previewRounding->value() * monitor->m_scale)));
        if (border > 0) {
            const CHyprColor            borderColor{static_cast<uint64_t>(state->config.previewBorderColor->value())};
            CRectPassElement::SRectData borderData;
            borderData.box   = outer;
            borderData.color = borderColor.modifyA(static_cast<float>(borderColor.a) * opacity);
            borderData.round = rounding;
            g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(borderData));
        }

        CBox inner{outer.x + border, outer.y + border, outer.w - border * 2, outer.h - border * 2};
        if (inner.w <= 0 || inner.h <= 0)
            return;

        const CHyprColor            fillColor{static_cast<uint64_t>(state->config.previewColor->value())};
        CRectPassElement::SRectData fillData;
        fillData.box   = inner;
        fillData.color = fillColor.modifyA(static_cast<float>(fillColor.a) * opacity);
        fillData.round = std::max(0, rounding - border);
        fillData.blur  = state->config.previewBlur->value();
        fillData.blurA = 0.48F * opacity;
        g_pHyprRenderer->m_renderPass.add(makeUnique<CRectPassElement>(fillData));
    }

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    pluginHandle = handle;

    const std::string runningHash = __hyprland_api_get_hash();
    const std::string headersHash = __hyprland_api_get_client_hash();
    if (runningHash != headersHash) {
        HyprlandAPI::addNotification(pluginHandle, "[nov-floating-snap] Hyprland version mismatch", CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("nov-floating-snap was built for a different Hyprland version");
    }

    state                        = makeUnique<SPluginState>();
    state->config.enabled = makeShared<Config::Values::CBoolValue>("plugin:nov_floating_snap:enabled", "Enable Aero-style drag snap zones", true);
    state->config.floatingModeOnly =
        makeShared<Config::Values::CBoolValue>("plugin:nov_floating_snap:floating_mode_only", "Activate only while Omarchy Floating Mode is on", true);
    state->config.columns =
        makeShared<Config::Values::CStringValue>("plugin:nov_floating_snap:columns", "Full-height snap columns: auto, 2, or 3", "auto",
                                                 Config::Values::SStringValueOptions{.validator = [](const Config::STRING& value) -> std::expected<void, std::string> {
                                                     if (value == "auto" || value == "2" || value == "3")
                                                         return {};
                                                     return std::unexpected("expected auto, 2, or 3");
                                                 }});
    state->config.edgeThreshold = makeShared<Config::Values::CIntValue>("plugin:nov_floating_snap:edge_threshold", "Logical pixels from a monitor edge that activate a zone", 12,
                                                                        Config::Values::SIntValueOptions{.min = 1, .max = 128});
    state->config.cornerRatio   = makeShared<Config::Values::CFloatValue>("plugin:nov_floating_snap:corner_ratio", "Fraction of each monitor edge reserved for corner zones",
                                                                          0.25F, Config::Values::SFloatValueOptions{.min = 0.05F, .max = 0.45F});
    state->config.previewColor  = makeShared<Config::Values::CColorValue>("plugin:nov_floating_snap:preview_color", "Snap preview fill color", 0x331e3a8a);
    state->config.previewBorderColor       = makeShared<Config::Values::CColorValue>("plugin:nov_floating_snap:preview_border_color", "Snap preview border color", 0xbd1d4ed8);
    state->config.previewBorderSize        = makeShared<Config::Values::CIntValue>("plugin:nov_floating_snap:preview_border_size", "Snap preview border size", 2,
                                                                                   Config::Values::SIntValueOptions{.min = 0, .max = 16});
    state->config.previewRounding          = makeShared<Config::Values::CIntValue>("plugin:nov_floating_snap:preview_rounding", "Snap preview corner radius", 8,
                                                                                   Config::Values::SIntValueOptions{.min = 0, .max = 64});
    state->config.previewBlur              = makeShared<Config::Values::CBoolValue>("plugin:nov_floating_snap:preview_blur", "Blur behind the snap preview", true);
    state->config.previewAnimationDuration = makeShared<Config::Values::CIntValue>(
        "plugin:nov_floating_snap:preview_animation_duration", "Snap preview animation duration in milliseconds", 200, Config::Values::SIntValueOptions{.min = 0, .max = 1000});

    // The dock reports where it sits and how much room it needs; halves stop
    // short of it so it stays visible.
    state->config.dockEdge    = makeShared<Config::Values::CStringValue>("plugin:nov_floating_snap:dock_edge", "Edge the dock sits on: none, top, bottom, left or right", "none");
    state->config.dockReserve = makeShared<Config::Values::CIntValue>("plugin:nov_floating_snap:dock_reserve", "Logical pixels kept free for the dock", 0,
                                                                      Config::Values::SIntValueOptions{.min = 0, .max = 1000});

    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.enabled);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.floatingModeOnly);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.columns);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.edgeThreshold);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.cornerRatio);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.previewColor);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.previewBorderColor);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.previewBorderSize);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.previewRounding);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.previewBlur);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.previewAnimationDuration);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.dockEdge);
    HyprlandAPI::addConfigValueV2(pluginHandle, state->config.dockReserve);

    state->pendingLuaRegistration = g_pEventLoopManager->doLaterLock([] {
        if (!state)
            return;
        HyprlandAPI::addLuaFunction(pluginHandle, "nov_floating_snap", "left", luaSnapLeft);
        HyprlandAPI::addLuaFunction(pluginHandle, "nov_floating_snap", "right", luaSnapRight);
        HyprlandAPI::addLuaFunction(pluginHandle, "nov_floating_snap", "maximize", luaSnapMaximize);
        HyprlandAPI::addLuaFunction(pluginHandle, "nov_floating_snap", "restore", luaSnapRestore);
    });

    state->mouseMoveListener      = Event::bus()->m_events.input.mouse.move.listen([](Vector2D cursor, Event::SCallbackInfo& info) { onMouseMove(cursor, info); });
    state->mouseButtonListener = Event::bus()->m_events.input.mouse.button.listen(
        [](IPointer::SButtonEvent event, Event::SCallbackInfo& info) { onMouseButton(event, info); });
    state->renderListener         = Event::bus()->m_events.render.stage.listen([](eRenderStage stageValue) { onRenderStage(stageValue); });
    state->windowDestroyListener  = Event::bus()->m_events.window.destroy.listen([](PHLWINDOWREF window) {
        if (!state)
            return;
        std::erase_if(state->records, [&](const auto& record) { return record.window == window; });
        if (state->drag && state->drag->target && state->drag->target->window() == window.lock())
            resetDrag();
    });
    state->windowActiveListener = Event::bus()->m_events.window.active.listen([](PHLWINDOW window, Desktop::eFocusReason) { onWindowActive(window); });
    state->windowFloatingListener = Event::bus()->m_events.window.floating.listen([](PHLWINDOW window) {
        if (state && Desktop::View::validMapped(window) && window->m_target && !window->m_target->floating())
            forgetRestoreBox(window);
    });
    HyprlandAPI::reloadConfig();
    return {"nov-floating-snap", "Edge snapping for native Omarchy floating workspaces", "Norbert Winter and contributors", "1.0.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (!state)
        return;

    clearPreview();
    state->pendingApply.reset();
    state->pendingLuaRegistration.reset();
    restoreTrackedWindows();
    state->mouseMoveListener.reset();
    state->mouseButtonListener.reset();
    state->renderListener.reset();
    state->windowDestroyListener.reset();
    state->windowFloatingListener.reset();
    state->windowActiveListener.reset();
    state.reset();
}
