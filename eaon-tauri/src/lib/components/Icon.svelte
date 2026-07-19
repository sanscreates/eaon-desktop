<script lang="ts">
  // The macOS app draws its iconography entirely from SF Symbols, which is
  // an Apple system framework — the glyphs are proprietary to Apple
  // platforms and the font can't be bundled into a Windows build. Lucide
  // (ISC licensed, ships as a real dependency below) is the closest
  // widely-used stroke-icon language to SF Symbols, so every name here is
  // mapped 1:1 by meaning against the actual systemName used in the Swift
  // views, rather than approximated by hand.
  import {
    SquarePen, FolderPlus, Folder, Search, Box, Settings, PanelLeft, Plus,
    ArrowUp, ArrowDown, Square, ChevronRight, ChevronLeft, ChevronDown, ChevronsUpDown,
    Ellipsis, Trash2, Pencil, Pin, X, Check, Copy, ThumbsUp, ThumbsDown, RefreshCw,
    Zap, Star, Glasses, Globe, Terminal, Brain, Puzzle, Image as ImageIcon, Server,
    Keyboard, Lock, ChartBar, Cpu, Key, Droplet, TriangleAlert, Info, Download, Share,
    ExternalLink, SlidersHorizontal, Sparkles, Laptop, Shield, Clock, MessageCircle,
    Quote, Palette, Monitor, Circle, CircleCheckBig, Minus, Play, Package,
    Volume2,
    type LucideIcon,
  } from "@lucide/svelte";

  let {
    name,
    size = 18,
    stroke = 1.7,
  }: { name: string; size?: number; stroke?: number } = $props();

  const ICONS: Record<string, LucideIcon> = {
    "new-chat": SquarePen,
    "folder-plus": FolderPlus,
    folder: Folder,
    "folder-fill": Folder,
    search: Search,
    cube: Box,
    gear: Settings,
    "gear-fill": Settings,
    sidebar: PanelLeft,
    plus: Plus,
    "arrow-up": ArrowUp,
    "arrow-down": ArrowDown,
    stop: Square,
    "chevron-right": ChevronRight,
    "chevron-left": ChevronLeft,
    "chevron-down": ChevronDown,
    "chevron-updown": ChevronsUpDown,
    ellipsis: Ellipsis,
    trash: Trash2,
    pencil: Pencil,
    pin: Pin,
    xmark: X,
    check: Check,
    copy: Copy,
    "thumbs-up": ThumbsUp,
    "thumbs-down": ThumbsDown,
    refresh: RefreshCw,
    bolt: Zap,
    "bolt-fill": Zap,
    star: Star,
    "star-fill": Star,
    glasses: Glasses,
    globe: Globe,
    terminal: Terminal,
    brain: Brain,
    puzzle: Puzzle,
    photo: ImageIcon,
    server: Server,
    keyboard: Keyboard,
    lock: Lock,
    chart: ChartBar,
    cpu: Cpu,
    key: Key,
    drop: Droplet,
    warning: TriangleAlert,
    info: Info,
    download: Download,
    share: Share,
    external: ExternalLink,
    sliders: SlidersHorizontal,
    sparkles: Sparkles,
    laptop: Laptop,
    shield: Shield,
    clock: Clock,
    message: MessageCircle,
    "text-quote": Quote,
    paint: Palette,
    desktop: Monitor,
    circle: Circle,
    "check-circle-fill": CircleCheckBig,
    "window-min": Minus,
    "window-max": Square,
    play: Play,
    speaker: Volume2,
    shippingbox: Package,
  };

  // Symbols that are a single silhouette shape read correctly filled solid,
  // matching the macOS app's use of the SF Symbol ".fill" variant for the
  // same glyph. Compound icons (a circle plus a separate checkmark, a
  // triangle plus a separate exclamation mark, etc.) are left as outlines —
  // Lucide has no second tone to keep an inner detail visible against a
  // solid fill the way SF Symbols' two-tone rendering does.
  const FILLED = new Set(["folder-fill", "star-fill", "bolt-fill", "gear-fill", "stop", "drop"]);

  const Cmp = $derived(ICONS[name] ?? Circle);
  const isFilled = $derived(FILLED.has(name));
</script>

<Cmp
  {size}
  strokeWidth={stroke}
  fill={isFilled ? "currentColor" : "none"}
  aria-hidden="true"
/>
