import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' as intl;

import '../l10n/app_localizations.dart';
import '../models/coach_response_type.dart';
import '../models/meal_entry.dart';
import '../models/meal_entry_source.dart';
import '../widgets/nutrition_header/macro_detail_modal.dart';
import '../widgets/nutrition_header/micro_detail_modal.dart';
import '../widgets/nutrition_header/nutrition_header.dart';
import '../models/thread_item.dart';
import '../providers/meal_providers.dart';
import '../providers/ui_providers.dart';
import '../services/claude_client.dart';
import '../services/coach_session_manager.dart';
import '../widgets/diary/month_calendar_popover.dart';
import '../widgets/empty/empty_today.dart';
import 'confirm_screen.dart';
import 'diary/coach_bubble.dart';
import 'diary/home_input.dart';
import 'diary/thread_meal_card.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dayFlipController;

  final _scroll = ScrollController();
  // Timestamp of the most-recent _scrollToBottom dispatch. Used to
  // coalesce rapid sequential scroll-to-bottom calls during the meal
  // save flow (meal-entry insert + coach-thinking bubble + coach reply
  // fire 3-4 scroll-to-bottom calls inside 500 ms, each animating 250 ms
  // → visible flicker). 300 ms cooldown collapses these into one.
  DateTime? _lastScrollDispatchAt;
  final Map<String, GlobalKey> _mealKeys = {};
  // True while a programmatic scroll is running. Suppresses both the
  // scroll-up-to-load-more trigger and the auto-follow-to-bottom on item add,
  // so a Verlauf-tap or post-save scroll lands cleanly.
  bool _programmaticScroll = false;
  // When true the diary hides coach bubbles, user questions and answers, so
  // the day reads as a plain list of what was eaten.
  bool _mealsOnly = false;
  int _lastTotalItemCount = 0;
  // Snapshot of meal IDs we last saw in the rendered thread; used to detect
  // genuinely-new meals (just saved) versus older meals appearing because the
  // user loaded an older day.
  Set<String> _lastThreadMealIds = <String>{};
  // Last scrollToBottomRequest bump value we already acted on. Used to skip
  // the existing bump on first build (initial state == 0) so we don't
  // jump to bottom every time the diary opens.
  int? _handledScrollToBottomBump;
  // Last scroll-intent token the coordinator already acted on. Mirrors the
  // bump guards above so the same intent doesn't re-fire across rebuilds.
  int _handledIntentToken = -1;
  // Direction-aware jump FAB. Tracks the last meaningful scroll direction
  // so the FAB matches the user's intent: scrolling down → offer "jump to
  // bottom", scrolling up → offer "jump to top". Hidden when at the edge
  // in the same direction (already at top / already at bottom).
  // null = no FAB visible.
  _ScrollDir? _scrollDir;
  // Direction of the most recent day-flip swipe. Drives the page-slide
  // animation on focusedDay change: swipe left (forward in time) makes
  // the new day slide in from the right; swipe right (back in time) from
  // the left. AppBar-picker / Today-button jumps default to no swipe
  // direction (treated as forward).
  _ScrollDir? _lastSwipeDir;
  double _lastScrollPixels = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _dayFlipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1.0, // start fully visible, no entrance animation
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: false);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _dayFlipController.dispose();
    super.dispose();
  }

  // Trigger the YAZIO-style page-slide on a day-flip: the body slides
  // in from the swipe direction. Single ListView, single ScrollController
  // (so no multi-position conflict like a two-child AnimatedSwitcher
  // would create); only the existing visual is re-animated as the new
  // day's items come in.
  void _runDayFlipAnimation() {
    _dayFlipController.forward(from: 0);
  }

  GlobalKey _keyForMeal(String mealId) =>
      _mealKeys.putIfAbsent(mealId, () => GlobalKey());

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // Single-day-view doesn't auto-load older days: history navigation
    // happens via the AppBar date picker. Older "scroll up = load more"
    // plumbing was retired in phase 7 of the diary refactor.
    //
    // Direction-aware FAB. Use a small dead zone (8px) so micro-jitter
    // doesn't flip the icon. Hide when there isn't enough room to scroll
    // in that direction (already near the edge).
    final delta = pos.pixels - _lastScrollPixels;
    _ScrollDir? next = _scrollDir;
    if (delta > 8) {
      // Scrolling down (toward bottom / today). Offer jump-to-bottom.
      next = pos.maxScrollExtent - pos.pixels > 400 ? _ScrollDir.down : null;
    } else if (delta < -8) {
      // Scrolling up (away from today, into history). Offer jump-to-top.
      next = pos.pixels > 400 ? _ScrollDir.up : null;
    }
    _lastScrollPixels = pos.pixels;
    if (next != _scrollDir) {
      setState(() => _scrollDir = next);
    }
  }

  void _scrollToTop({bool animate = true}) {
    if (!_scroll.hasClients) return;
    if (animate) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(0);
    }
  }

  void _scrollToBottom({bool animate = true, bool force = false}) {
    if (!_scroll.hasClients) return;
    // Coalesce rapid sequential scroll-to-bottoms (multi-bubble save
    // flow). If we just dispatched a scroll within the last 300 ms,
    // skip this one - the existing scroll is enough, and stacking
    // animations on top of each other reads as flicker. Callers that
    // need to bypass (e.g. user-triggered tab switch) can pass force.
    if (!force) {
      final now = DateTime.now();
      if (_lastScrollDispatchAt != null &&
          now.difference(_lastScrollDispatchAt!) <
              const Duration(milliseconds: 300)) {
        return;
      }
      _lastScrollDispatchAt = now;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          pos,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(pos);
      }
    });
  }

  // Scrolls a keyed widget to the top of the viewport. Retries with a short
  // delay because the GlobalKey's currentContext / RenderBox can be null for
  // a frame or two after a save or a day switch.
  //
  // We compute the target scroll offset directly with getOffsetToReveal
  // rather than Scrollable.ensureVisible: ensureVisible NO-OPs when the item
  // sits inside the day-flip SlideTransition (tester report: "lands on
  // yesterday but not at the entry"), and a backdated entry that is rendered
  // off-screen above the fold was never reached. getOffsetToReveal reads the
  // viewport/item geometry, so it works for any built item, on- or off-screen.
  Future<void> _scrollKeyToTop(GlobalKey key) async {
    _programmaticScroll = true;
    // 1) Wait for the entry's key to attach (post-save / day-switch can lag a
    // frame or two before the card's RenderBox exists).
    RenderBox? box;
    for (var attempt = 0; attempt < 12; attempt++) {
      if (!mounted) {
        _programmaticScroll = false;
        return;
      }
      final ro = key.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && _scroll.hasClients) {
        box = ro;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 80));
    }
    if (box == null || !mounted) {
      debugPrint('[SCROLLDBG] box never attached (key not laid out)');
      _programmaticScroll = false;
      return;
    }
    // 2) Re-assert until the layout settles. After a save the coach bubble
    // inflates then collapses the content height (observed on-sim:
    // maxScrollExtent swinging 784 -> 503 within ~1s), so a single
    // getOffsetToReveal computes a STALE target and the view lands off the
    // entry. Recompute + animate until the target stops moving between passes
    // (mirrors the dayTop re-pin loop). _programmaticScroll stays true so the
    // coach-follow heuristic can't fight us mid-settle.
    double? lastTarget;
    for (var pass = 0; pass < 8; pass++) {
      if (!mounted) break;
      final ro = key.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !_scroll.hasClients) break;
      final viewport = RenderAbstractViewport.of(ro);
      final target = viewport
          .getOffsetToReveal(ro, 0.0)
          .offset
          .clamp(0.0, _scroll.position.maxScrollExtent);
      debugPrint('[SCROLLDBG] pass=$pass before=${_scroll.position.pixels.toStringAsFixed(1)} '
          'target=${target.toStringAsFixed(1)} max=${_scroll.position.maxScrollExtent.toStringAsFixed(1)}');
      if (lastTarget != null && (target - lastTarget).abs() < 2.0) {
        // Layout settled: make sure we are exactly on target, then stop.
        if ((_scroll.position.pixels - target).abs() > 2.0) {
          _scroll.jumpTo(target);
        }
        debugPrint('[SCROLLDBG] settled pass=$pass target=${target.toStringAsFixed(1)} '
            'pixels=${_scroll.position.pixels.toStringAsFixed(1)} '
            'max=${_scroll.position.maxScrollExtent.toStringAsFixed(1)}');
        break;
      }
      await _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      lastTarget = target;
      await Future.delayed(const Duration(milliseconds: 90));
    }
    debugPrint('[SCROLLDBG] loop end pixels=${_scroll.hasClients ? _scroll.position.pixels.toStringAsFixed(1) : "n/a"}');
    _programmaticScroll = false;
  }

  Future<void> _scrollToNewMeal(String mealId) async {
    final key = _mealKeys[mealId];
    if (key == null) return;
    await _scrollKeyToTop(key);
  }

  // _logForDay (the past-day-input-sheet entry point) has been retired in
  // the Single-Day-View refactor. Past-day logging now happens by switching
  // focusedDay via the AppBar picker and using the normal input bar; the
  // confirm sheet's date/time pill carries the right createdAt.

  // Title that the AppBar shows above the diary. Today and yesterday get
  // their named-day form; older days are formatted as "weekday, day. month"
  // (e.g. "So, 8. Juni" / "Sun, 8 Jun") using the locale's short month.
  // True when the diary is sitting on today (the most common case). Drives
  // the conditional Today-jump button in the AppBar - hidden when there's
  // nowhere to jump back to.
  bool _isFocusedOnToday(WidgetRef ref) {
    final focused = ref.watch(focusedDayProvider);
    final now = DateTime.now();
    return focused.year == now.year &&
        focused.month == now.month &&
        focused.day == now.day;
  }

  String _focusedDayTitle(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final focused = ref.watch(focusedDayProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final delta = today.difference(focused).inDays;
    if (delta == 0) return l10n.todayHeader;
    if (delta == 1) return l10n.yesterdayHeader;
    final localeTag = Localizations.localeOf(context).toLanguageTag();
    final weekday = intl.DateFormat.E(localeTag).format(focused);
    final dayMonth = intl.DateFormat.MMMd(localeTag).format(focused);
    return '$weekday, $dayMonth';
  }

  // Opens the disclaimer bottom-sheet (Task #88.6). Reuses the same body
  // text shown in the onboarding disclaimer step so the legal surface
  // stays single-source. Once the standalone disclaimer page (#88.9) is
  // live we'll add a "Mehr dazu" link to it here.
  void _showDisclaimerSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.coachDisclaimerSheetTitle,
                style: Theme.of(sheetCtx)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.onboardingDisclaimerBody,
                style: Theme.of(sheetCtx)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurface, height: 1.45),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(sheetCtx),
                  child: Text(l10n.coachDisclaimerSheetClose),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final initial = ref.read(focusedDayProvider);
    // Pull the meal-day index off mealsByDayProvider so the popover can
    // render an amber dot under each day that has at least one entry.
    final mealsByDay = ref.read(mealsByDayProvider);
    final mealDays = mealsByDay.keys.toSet();
    final picked = await showMonthCalendarPopover(
      context,
      focused: initial,
      mealDays: mealDays,
      firstSelectable: DateTime(now.year - 1, now.month, now.day),
      lastSelectable: DateTime(now.year, now.month, now.day),
    );
    if (picked == null) return;
    final normalized = DateTime(picked.year, picked.month, picked.day);
    // Drives the Single-Day-View: NutritionHeader, thread body and AppBar
    // title all rebind to this day.
    ref.read(focusedDayProvider.notifier).state = normalized;
    final today = DateTime(now.year, now.month, now.day);
    requestScroll(
      ref,
      target: normalized == today ? ScrollTarget.bottom : ScrollTarget.dayTop,
      day: normalized,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Single-day-view: body binds to the focused day's thread directly.
    // Multi-day plumbing (loadedDaysProvider / loadedThreadProvider) was
    // retired in phase 7 of the diary refactor.
    final focusedDayThread = ref.watch(focusedDayThreadProvider);
    final focusedDayItems = focusedDayThread.valueOrNull ?? const [];
    final focusedDay = ref.watch(focusedDayProvider);

    // --- Scroll coordinator (Phase 1: day-change) -----------------------
    // One intent drives day-change scrolling. Resolve it only on the build
    // where the focused day's data is actually present (data-driven, not a
    // fixed timer) so a past-day switch reliably lands at the day's top
    // instead of mid-conversation. dayTop pins to 0; bottom keeps today
    // anchored on the input. (meal anchoring is wired in Phase 2.)
    final scrollIntent = ref.watch(scrollIntentProvider);
    if (scrollIntent != null &&
        scrollIntent.token != _handledIntentToken &&
        focusedDayThread.hasValue &&
        !focusedDayThread.isLoading) {
      final focusedKey =
          DateTime(focusedDay.year, focusedDay.month, focusedDay.day);
      if (scrollIntent.day == null || scrollIntent.day == focusedKey) {
        _handledIntentToken = scrollIntent.token;
        final target = scrollIntent.target;
        final onlyIfNearBottom = scrollIntent.onlyIfNearBottom;
        final mealId = scrollIntent.mealId;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          switch (target) {
            case ScrollTarget.dayTop:
              // Data-gated re-assert: this build already has the focused
              // day's items, but coach bubbles / images can still measure
              // over the next frames. Re-pin to 0 a few times so layout
              // settling can't leave us mid-day.
              _programmaticScroll = true;
              for (var i = 0; i < 6; i++) {
                if (!mounted) break;
                if (_scroll.hasClients) _scroll.jumpTo(0);
                await Future<void>.delayed(const Duration(milliseconds: 50));
              }
              _programmaticScroll = false;
              break;
            case ScrollTarget.bottom:
              if (onlyIfNearBottom) {
                if (_scroll.hasClients) {
                  final pos = _scroll.position;
                  if (pos.maxScrollExtent - pos.pixels < 200) {
                    _scrollToBottom();
                  }
                }
              } else {
                _scrollToBottom(force: true);
              }
              break;
            case ScrollTarget.meal:
              debugPrint('[SCROLLDBG] intent=meal mealId=$mealId day=${scrollIntent.day}');
              if (mealId != null) {
                // On a same-day save the day doesn't reload, so the
                // coordinator can fire before the new meal's card (and its
                // GlobalKey) is in the tree, and _scrollToNewMeal would
                // no-op on a missing key. Wait for the key to register
                // (up to ~1.2s), then anchor the meal at the top (coach
                // reply renders below it).
                for (var i = 0; i < 12; i++) {
                  if (!mounted) break;
                  if (_mealKeys.containsKey(mealId)) {
                    await _scrollToNewMeal(mealId);
                    break;
                  }
                  await Future<void>.delayed(
                      const Duration(milliseconds: 100));
                }
                if (!mounted) break;
                // 1.5s highlight pulse as a belt-and-braces visual anchor.
                ref.read(highlightedMealIdProvider.notifier).state = mealId;
                Future.delayed(const Duration(milliseconds: 1800), () {
                  if (!mounted) return;
                  if (ref.read(highlightedMealIdProvider) == mealId) {
                    ref.read(highlightedMealIdProvider.notifier).state = null;
                  }
                });
              }
              break;
          }
        });
      }
    }

    final coachLoading = ref.watch(insightLoadingProvider);
    final mealsAll = ref.watch(mealsProvider).valueOrNull ?? const [];
    // kcal / macro / micronutrient totals are now consumed by
    // NutritionHeader directly via providers, so the diary build no
    // longer needs to recompute them locally.

    // Detect genuinely-new meals by looking at the thread itself: we collect
    // all meal IDs currently rendered and diff against the previous snapshot.
    // This catches the moment the new meal's ThreadItem lands in
    // loadedThreadProvider (the mealsAll stream often fires earlier, before
    // the card is actually in the tree, so scrolling then would miss the key).
    final currentThreadMealIds = <String>{};
    for (final item in focusedDayItems) {
      if (item.type == ThreadItemType.meal && item.mealId != null) {
        currentThreadMealIds.add(item.mealId!);
      }
    }
    final newlyRenderedMealIds =
        currentThreadMealIds.difference(_lastThreadMealIds);
    final totalItems = focusedDayItems.length;
    // Follow a coach response down to the bottom, but only if the user is
    // already near it (ambient update, not an explicit action). Save and
    // day-change scrolling is owned by the ScrollIntent coordinator above.
    if (totalItems > _lastTotalItemCount &&
        _lastTotalItemCount > 0 &&
        newlyRenderedMealIds.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && !_programmaticScroll) {
          final pos = _scroll.position;
          if (pos.maxScrollExtent - pos.pixels < 200) {
            debugPrint('[SCROLLDBG] coach-follow scrollToBottom (totalItems=$totalItems '
                'pixels=${pos.pixels.toStringAsFixed(1)} max=${pos.maxScrollExtent.toStringAsFixed(1)})');
            _scrollToBottom();
          }
        }
      });
    }
    _lastTotalItemCount = totalItems;
    _lastThreadMealIds = currentThreadMealIds;

    // Explicit "scroll to bottom" request - currently bumped when the user
    // submits a chat question. Bypasses the ambient "near-bottom-only"
    // heuristic so a question typed while scrolled into yesterday still
    // surfaces the question (and the eventual reply) for the user.
    final scrollBottomBump = ref.watch(scrollToBottomRequestProvider);
    if (_handledScrollToBottomBump == null) {
      _handledScrollToBottomBump = scrollBottomBump;
    } else if (scrollBottomBump != _handledScrollToBottomBump) {
      _handledScrollToBottomBump = scrollBottomBump;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    }

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // The meals-only filter only helps once there's something to filter on
    // the focused day: at least one meal AND at least one coach bubble /
    // question / answer.
    final canFilter =
        focusedDayItems.any((i) => i.type == ThreadItemType.meal) &&
            focusedDayItems.any((i) => i.type != ThreadItemType.meal);

    return Scaffold(
      appBar: AppBar(
        // Past-day adds an eyebrow above the date title, which needs
        // more vertical room than the default 56 px toolbar. Bump to 64
        // when not on today; today keeps the default for a tighter look.
        // 8 px delta is small enough to not jitter perceptibly on
        // day-switch, large enough to stop the eyebrow clipping.
        toolbarHeight: _isFocusedOnToday(ref) ? null : 64,
        title: Builder(
          builder: (ctx) {
            // Date IS the screen title (per Build +36 design rework).
            // On today: bare titleLarge + caret. On a past day: a
            // labelSmall Mono eyebrow ("VERGANGENER TAG") above, plus a
            // primaryContainer "Heute" chip next to the date as the
            // one-tap reset. Tap on the title/caret still opens the
            // date picker via _pickDate.
            final isToday = _isFocusedOnToday(ref);
            final l10nLocal = AppLocalizations.of(ctx);
            final dayTitle = _focusedDayTitle(ctx);
            final dateTrigger = InkWell(
              onTap: () => _pickDate(context),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      dayTitle,
                      style: textTheme.titleLarge?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      color: scheme.outline,
                      size: 22,
                    ),
                  ],
                ),
              ),
            );
            if (isToday) return dateTrigger;
            // Past day: eyebrow + date (no inline "Heute"-Chip). The
            // back-to-today TextButton lives in actions (right side) to
            // match the Apple/Google Calendar pattern - clearer action
            // affordance + no tap-target competition with the date tap.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10nLocal.diaryPastDayEyebrow.toUpperCase(),
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.secondary,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                dateTrigger,
              ],
            );
          },
        ),
        centerTitle: false,
        actions: [
          // Today-jump: on past days, a single tap returns to today
          // (Apple/Google Calendar pattern). Hidden when already on today
          // so the action cluster stays calm. Build +36 v2: moved from
          // the title row back to actions per re-test feedback - the
          // inline chip read as a label, not an action.
          if (!_isFocusedOnToday(ref))
            TextButton(
              onPressed: () {
                final now = DateTime.now();
                final today = DateTime(now.year, now.month, now.day);
                ref.read(focusedDayProvider.notifier).state = today;
                requestScroll(ref, target: ScrollTarget.bottom, day: today);
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: const Size(0, 36),
                foregroundColor: scheme.primary,
              ),
              child: Text(AppLocalizations.of(context).todayHeader),
            ),
          // Disclaimer (Task #88.6). Sits at the LEFT of the action cluster
          // so the user's eye reaches it before the filter/settings group.
          // lock_outline is the most-generic "security/safety" glyph we
          // could pick - shield_outlined still read as a "warning" cue to
          // Vanessa; the lock is calm and doesn't suggest danger.
          //
          // Hidden on past days (today is the primary logging surface).
          if (_isFocusedOnToday(ref))
            IconButton(
              icon: const Icon(Icons.lock_outline),
              tooltip: AppLocalizations.of(context).coachDisclaimerBadge,
              onPressed: () => _showDisclaimerSheet(context),
            ),
          if (canFilter)
          IconButton(
            icon: Icon(_mealsOnly
                ? Icons.filter_alt
                : Icons.filter_alt_outlined),
            tooltip: _mealsOnly
                ? AppLocalizations.of(context).diaryFilterShowAll
                : AppLocalizations.of(context).diaryFilterMealsOnly,
            onPressed: () {
              setState(() => _mealsOnly = !_mealsOnly);
              final l10n = AppLocalizations.of(context);
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  content: Text(_mealsOnly
                      ? l10n.diaryFilterOnMsg
                      : l10n.diaryFilterOffMsg),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ));
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: AppLocalizations.of(context).settingsTooltip,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          // Header height varies (~50px without micros, ~75px with).
          // Use a comfortable upper bound - Material clips/handles the
          // actual content height.
          preferredSize: const Size.fromHeight(82),
          child: Material(
            color: scheme.surface,
            elevation: 0,
            child: NutritionHeader(
              onMacroTap: (key) {
                final macro = switch (key) {
                  'kcal' => MacroKey.kcal,
                  'protein' => MacroKey.protein,
                  'carbs' => MacroKey.carbs,
                  'fat' => MacroKey.fat,
                  _ => null,
                };
                if (macro != null) showMacroDetailModal(context, macro);
              },
              onMicroTap: (key) => showMicroDetailModal(context, key),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                GestureDetector(
                  onTap: () => FocusScope.of(context).unfocus(),
                  // Horizontal swipe between days: a fast flick changes
                  // focusedDay by one. Slidable rows have their own
                  // horizontal-drag recognizer that wins inside their
                  // hit area, so meal-row swipe-actions keep working;
                  // this handler fires only on the empty space, the
                  // header overlap, and coach rows that aren't
                  // Slidable. Future days are blocked (no future logs
                  // in this MVP).
                  onHorizontalDragEnd: (details) {
                    final v = details.primaryVelocity ?? 0;
                    if (v.abs() < 250) return;
                    final focused = ref.read(focusedDayProvider);
                    final now = DateTime.now();
                    final today = DateTime(now.year, now.month, now.day);
                    if (v < 0) {
                      // Swipe left → forward in time (newer day). Cap
                      // at today.
                      final next = focused.add(const Duration(days: 1));
                      if (!next.isAfter(today)) {
                        HapticFeedback.lightImpact();
                        _lastSwipeDir = _ScrollDir.up;
                        ref.read(focusedDayProvider.notifier).state = next;
                        requestScroll(
                          ref,
                          target: next == today
                              ? ScrollTarget.bottom
                              : ScrollTarget.dayTop,
                          day: next,
                        );
                        _runDayFlipAnimation();
                      }
                    } else {
                      // Swipe right → back in time (older day).
                      HapticFeedback.lightImpact();
                      _lastSwipeDir = _ScrollDir.down;
                      final prev = focused.subtract(const Duration(days: 1));
                      ref.read(focusedDayProvider.notifier).state = prev;
                      requestScroll(ref, target: ScrollTarget.dayTop, day: prev);
                      _runDayFlipAnimation();
                    }
                  },
                  behavior: HitTestBehavior.opaque,
                  child: SlideTransition(
                    // YAZIO-style page slide: the body slides in from
                    // the swipe direction whenever focusedDay flips.
                    // Begin offset: +x for swipe-left (new day comes
                    // from the right), -x for swipe-right. End at 0.
                    // Controller's `value: 1.0` initial means no
                    // entrance animation on first render.
                    position: Tween<Offset>(
                      begin: Offset(
                          _lastSwipeDir == _ScrollDir.down ? -1.0 : 1.0,
                          0),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _dayFlipController,
                      curve: Curves.easeOutCubic,
                    )),
                    child: ListView(
                      controller: _scroll,
                      // Lay out the whole day, not just the viewport +/- 250px
                      // default. Without this, a backdated entry that sorts far
                      // off-screen (e.g. a 07:00 meal added while scrolled to the
                      // evening) is built but NOT laid out, so its GlobalKey has
                      // no attached RenderBox and the scroll-to-meal anchor can't
                      // reach it (it silently no-ops). A day's thread is bounded
                      // (~10-15 entries), so a generous cacheExtent forces every
                      // entry to lay out and keeps getOffsetToReveal reliable.
                      cacheExtent: 5000,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      children: _buildSlivers(
                      context: context,
                      ref: ref,
                      items: focusedDayItems,
                      mealsAll: mealsAll,
                      // IDs of meals whose coach call is currently in flight.
                      // _buildSlivers renders a thinking bubble after each
                      // such meal so multiple parallel calls (rapid logs)
                      // each get their own visible loading state.
                      inFlightMealIds: ref.watch(coachSessionProvider),
                      scheme: scheme,
                      textTheme: textTheme,
                      mealsOnly: _mealsOnly,
                    ),
                    ),
                  ),
                ),
                if (_scrollDir != null)
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: FloatingActionButton.small(
                      // Stable heroTag per direction so the swap doesn't
                      // throw a duplicate-tag exception during the rebuild.
                      heroTag: _scrollDir == _ScrollDir.up
                          ? 'scroll-top'
                          : 'scroll-bottom',
                      onPressed: _scrollDir == _ScrollDir.up
                          ? () => _scrollToTop()
                          : () {
                              // Dismiss the keyboard first when present -
                              // otherwise maxScrollExtent is measured with
                              // the input area pushed up, and the "bottom"
                              // we scroll to ends up partly hidden behind
                              // the keyboard / suggestion strip. ~280 ms
                              // matches the iOS keyboard collapse so the
                              // layout has settled before we measure again.
                              FocusScope.of(context).unfocus();
                              Future.delayed(
                                const Duration(milliseconds: 280),
                                _scrollToBottom,
                              );
                            },
                      tooltip: _scrollDir == _ScrollDir.up
                          ? AppLocalizations.of(context).homeScrollToTop
                          : AppLocalizations.of(context).homeScrollToBottom,
                      elevation: 2,
                      child: Icon(_scrollDir == _ScrollDir.up
                          ? Icons.arrow_upward
                          : Icons.arrow_downward),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      // Coach-thinking banner sits directly above the input bar so the
       // cause / effect chain is visible: user taps send, banner appears
       // right next to where their finger was. Sticky so even if she
       // scrolls away in the diary the signal stays in view.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (coachLoading)
            CoachLoadingBanner(scheme: scheme, textTheme: textTheme),
          const HomeInput(),
        ],
      ),
    );
  }

  // Single-day thread body. Phase 2 of the diary refactor: the diary now
  // renders ONLY the focused day's items, top-to-bottom in chronological
  // order. No DaySeparator (the day is the AppBar title), no
  // EmptyDayRange (only one day visible at a time), no multi-day loop.
  //
  // Past days where the user logged nothing show a quiet empty-state
  // line below the header instead of the previous "Keine Einträge"
  // subtitle on the separator.
  List<Widget> _buildSlivers({
    required BuildContext context,
    required WidgetRef ref,
    required List<ThreadItem> items,
    required List<MealEntry> mealsAll,
    required Set<String> inFlightMealIds,
    required ColorScheme scheme,
    required TextTheme textTheme,
    bool mealsOnly = false,
  }) {
    final widgets = <Widget>[];
    final mealsById = {for (final m in mealsAll) m.id: m};

    // Past-day awareness: the "Coach pausiert" hint used to sit at the
    // top of the thread as a persistent banner. Beta feedback called it
    // "too in-your-face"; the cue now fires as a one-shot snackbar
    // appended to the save confirmation (see ConfirmScreen._appendToThread).
    // We still compute isPast because the empty-state copy varies.
    final focusedDay = ref.read(focusedDayProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isPast = focusedDay.isBefore(today);

    // First-launch shortcut: no meals exist anywhere yet, show the
    // EmptyToday welcome card. Phase 5 swaps this for a per-day empty
    // state with paper-styled "Noch nichts geloggt" lettering.
    if (mealsAll.isEmpty) {
      widgets.add(const EmptyToday());
      return widgets;
    }

    if (items.isEmpty) {
      // Focused day has no items but the user has logged elsewhere.
      // Reuse the EmptyToday card so the past-day empty state matches
      // the today-empty visual (dotted border, icon, italic headline),
      // just with past-tense copy via isPast.
      widgets.add(EmptyToday(isPast: isPast));
      return widgets;
    }

    for (final item in items) {
      // Meals-only filter: skip coach bubbles, questions and answers so the
      // day reads as a plain log of what was eaten.
      if (mealsOnly && item.type != ThreadItemType.meal) continue;
      switch (item.type) {
        case ThreadItemType.meal:
          final meal = mealsById[item.mealId];
          if (meal == null) continue;
          widgets.add(KeyedSubtree(
            key: _keyForMeal(meal.id),
            child: ThreadMealCard(
              meal: meal,
              onEdit: () => _editMeal(context, meal),
              onDuplicate: () => _duplicateMeal(ref, meal),
              onDelete: () => _confirmDelete(context, ref, meal),
            ),
          ));
          // TEMP diagnostic (Lotte ordering bug, 2026-06-22): show the
          // SORT time (ThreadItem.timestamp, drives position) vs the CHIP
          // time (MealEntry.createdAt, what the card shows) per entry, in
          // render order. If they diverge for an out-of-place entry, that
          // pinpoints the bug. Remove after diagnosing.
          () {
            String t(DateTime d) =>
                '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
            final diverges = item.timestamp != meal.createdAt;
            widgets.add(Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Text(
                'DBG  sort=${t(item.timestamp)}  chip=${t(meal.createdAt)}  ${diverges ? "⟂ DIVERGIERT" : "ok"}  id=${meal.id.length > 6 ? meal.id.substring(meal.id.length - 6) : meal.id}',
                style: TextStyle(
                    fontSize: 11,
                    color: diverges
                        ? const Color(0xFFB00020)
                        : const Color(0xFF888888)),
              ),
            ));
          }();
          // In-thread thinking bubble: appears directly after any meal
          // whose coach call is currently in flight. Suppressed in
          // meals-only mode (same as actual coach bubbles) so the
          // filtered view stays a plain log of what was eaten.
          if (!mealsOnly && inFlightMealIds.contains(meal.id)) {
            widgets.add(const CoachThinkingBubble());
          }
        case ThreadItemType.coachResponse:
          widgets.add(CoachBubble(
            text: item.text ?? '',
            isAnswer: false,
            mealId: item.mealId,
            responseType: item.responseType ?? CoachResponseType.normal,
          ));
        case ThreadItemType.userQuestion:
          widgets.add(UserBubble(text: item.text ?? ''));
        case ThreadItemType.coachAnswer:
          widgets.add(CoachBubble(
            text: item.text ?? '',
            isAnswer: true,
            mealId: item.mealId,
            responseType: item.responseType ?? CoachResponseType.normal,
          ));
      }
    }
    return widgets;
  }
}

enum _ScrollDir { up, down }

MealParseResult _toParseResult(MealEntry meal) => MealParseResult(
      isMeal: true,
      rejectionReason: null,
      summary: meal.summary,
      kcal: meal.kcal,
      proteinG: meal.proteinG,
      carbsG: meal.carbsG,
      fatG: meal.fatG,
      portionAmount: meal.portionAmount,
      portionUnit: meal.portionUnit,
      portionAlias: meal.portionAlias,
      safetyWarnings: meal.safetyWarnings,
    );

void _editMeal(BuildContext context, MealEntry meal) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ConfirmScreen(
        rawText: meal.rawText,
        parsed: _toParseResult(meal),
        existingMealId: meal.id,
        existingCreatedAt: meal.createdAt,
        source: MealEntrySource.edit,
      ),
    ),
  );
}

Future<void> _duplicateMeal(WidgetRef ref, MealEntry meal) async {
  // Anchor the duplicate to the day the user is CURRENTLY viewing - not the
  // original meal's day, not today. That matches the "I want this again"
  // intent: if I'm on Yesterday's diary and duplicate Yesterday's lunch,
  // the duplicate should appear under Yesterday. If I'm on Today, it
  // should appear under Today. With the old `DateTime.now()` default the
  // duplicate would silently land on Today even when the user was viewing
  // a past day, so they saw "nothing happen".
  //
  // For today's diary use the current wall-clock time; for a past day use
  // noon as a neutral anchor (no implicit "now" on a day that's over).
  final now = DateTime.now();
  final focused = ref.read(focusedDayProvider);
  final today = DateTime(now.year, now.month, now.day);
  final isToday = focused.year == today.year &&
      focused.month == today.month &&
      focused.day == today.day;
  final cloneTime = isToday
      ? now
      : DateTime(focused.year, focused.month, focused.day, 12, 0);
  final clone = MealEntry(
    id: now.microsecondsSinceEpoch.toString(),
    createdAt: cloneTime,
    rawText: meal.rawText,
    summary: meal.summary,
    kcal: meal.kcal,
    proteinG: meal.proteinG,
    carbsG: meal.carbsG,
    fatG: meal.fatG,
    portionAmount: meal.portionAmount,
    portionUnit: meal.portionUnit,
    portionAlias: meal.portionAlias,
    safetyWarnings: meal.safetyWarnings,
    // Carry micronutrient estimates - duplicate is semantically "same meal
    // again", not a re-parse. Dropping them would mean the donut sits at
    // half-credit on a double-portion day.
    micronutrients: meal.micronutrients,
  );
  await ref.read(mealRepositoryProvider).save(clone);
  await ref
      .read(threadRepositoryProvider)
      .add(ThreadItem.meal(mealId: clone.id, at: clone.createdAt));
}

Future<void> _confirmDelete(
    BuildContext context, WidgetRef ref, MealEntry meal) async {
  final l10n = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.homeMealDeleteTitle(meal.summary)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(l10n.commonDelete),
        ),
      ],
    ),
  );
  if (confirmed == true) {
    await ref.read(mealRepositoryProvider).delete(meal.id);
    await ref
        .read(threadRepositoryProvider)
        .removeMeal(meal.id, meal.createdAt);
  }
}
