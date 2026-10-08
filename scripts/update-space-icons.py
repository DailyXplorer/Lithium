#!/usr/bin/env python3
"""Write the space icon picker's index (Resources/SpaceIcons.tsv) and bundle the icons it lists.

The icons are Phosphor regular SVGs (MIT), taken from the @phosphor-icons/core npm package and
copied into Resources/Icons next to the app's own. Each index line is `name<TAB>keywords`: the
picker searches the name's words and the keywords by word prefix. Icons already bundled are
left as they are. Run again after editing GROUPS: `python3 scripts/update-space-icons.py`.
"""

import io
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "Sources/Lithium/Resources/Icons"
INDEX = ROOT / "Sources/Lithium/Resources/SpaceIcons.tsv"
PACKAGE = "https://registry.npmjs.org/@phosphor-icons/core/-/core-2.1.1.tgz"

# (keywords shared by the group, [icon or (icon, its own keywords)]), in picker order.
GROUPS = [
    ("general", [
        ("globe-simple", "web internet world browse personal"), ("folder-simple", "files projects"),
        ("lock-simple", "private secure"), ("highlighter", "notes highlight research"), ("hand", "personal"),
    ]),
    ("work office job business", [
        ("briefcase", "career"), "buildings", "building-office", "bank", ("calendar", "schedule"),
        "calendar-check", "calendar-blank", "clipboard", "clipboard-text", ("kanban", "project tasks"),
        "presentation-chart", "chart-bar", "chart-line", "chart-pie", "table", "files", "file-text",
        ("note", "notes"), ("notepad", "notes"), ("notebook", "notes journal"), "pencil-line",
        ("envelope-simple", "mail email"), ("paper-plane-tilt", "send mail"), "phone-call",
        ("user-circle", "account profile"), ("users-three", "team"), ("target", "goals"),
        "flag-banner", ("handshake", "deal clients"), "archive", ("tray", "inbox"),
    ]),
    ("home house life family", [
        "house", "house-line", ("couch", "living"), ("bed", "sleep"), "bathtub", "armchair",
        "lamp-pendant", "key", "door", ("fire-simple", "fireplace"), ("washing-machine", "laundry chores"),
        ("broom", "cleaning chores"), ("plant", "garden"), ("flower", "garden"), ("tree", "garden"),
        ("garage", "car"), "bell-simple", ("gift", "present birthday"), ("cake", "birthday party"),
    ]),
    ("school learning study education class", [
        ("graduation-cap", "university college"), ("book", "read"), ("book-open", "read"),
        ("books", "library read"), "student", ("chalkboard-teacher", "teacher"), ("exam", "test"),
        ("pen-nib", "writing"), "ruler", ("math-operations", "math"), ("atom", "science physics"),
        ("flask", "science chemistry lab"), ("microscope", "science biology lab"),
        ("globe-hemisphere-west", "geography world"), ("translate", "language"),
        ("lightbulb", "idea"), ("brain", "think"),
    ]),
    ("money finance bank pay budget", [
        "wallet", "coins", "money", ("credit-card", "card"), ("currency-dollar", "dollar usd"),
        ("currency-eur", "euro"), ("currency-gbp", "pound"), ("currency-btc", "bitcoin crypto"),
        ("piggy-bank", "savings"), ("receipt", "bills expenses"), ("shopping-bag-open", "shopping"),
        ("tag", "price"), "ticket", ("percent", "sale"), ("scales", "law legal"),
    ]),
    ("travel trip vacation holiday places", [
        ("airplane", "flight"), ("airplane-tilt", "flight"), ("airplane-in-flight", "flight"),
        ("suitcase", "luggage"), ("suitcase-rolling", "luggage"), ("map-trifold", "maps"),
        ("map-pin", "location place"), "compass", ("globe-hemisphere-east", "world"),
        ("mountains", "hiking outdoors"), ("tent", "camping outdoors"), ("backpack", "hiking"),
        ("car", "drive"), ("car-simple", "drive"), ("bicycle", "bike cycling"), "train",
        "train-simple", "boat", ("sailboat", "sailing"), "bus", ("taxi", "cab"),
        ("road-horizon", "road trip"), ("umbrella-simple", "beach"), "city", ("island", "beach"),
    ]),
    ("music media audio video movie entertainment", [
        "music-note", "music-notes", ("headphones", "listen"), ("microphone", "podcast"),
        ("microphone-stage", "sing karaoke"), "guitar", ("piano-keys", "piano"), "speaker-high",
        ("queue", "playlist"), ("vinyl-record", "record"), ("radio", "podcast"), "record",
        ("film-slate", "cinema"), ("film-strip", "cinema"), ("camera", "photo photography"),
        "video-camera", ("television", "tv shows"), ("monitor-play", "streaming"), ("play-circle", "watch"),
    ]),
    ("code tech development programming computer dev", [
        "code", "code-simple", ("terminal", "shell"), ("terminal-window", "shell"), ("bug", "debug"),
        "brackets-curly", ("git-branch", "github"), "git-commit", "git-merge",
        ("git-pull-request", "github review"), "git-fork", ("cpu", "hardware"), ("hard-drives", "server"),
        ("database", "data"), ("cloud-arrow-up", "upload"), "desktop", "laptop", ("device-mobile", "phone"),
        ("wifi-high", "network"), ("robot", "ai bot"), "function", "file-code", "tree-structure",
    ]),
    ("game games fun play", [
        ("game-controller", "gaming console"), ("dice-five", "board"), ("dice-one", "board"),
        ("puzzle-piece", "extensions"), ("cards", "poker"), "crown", ("trophy", "win"), ("medal", "award"),
        ("confetti", "party celebrate"), ("smiley", "happy"), "smiley-wink", "ghost", "alien",
        ("balloon", "party"), "cube", "shooting-star",
    ]),
    ("sport sports fitness exercise gym", [
        ("barbell", "weights"), "basketball", "football", ("soccer-ball", "football"), "tennis-ball",
        "baseball", ("person-simple-run", "running"), ("person-simple-walk", "walking"),
        ("person-simple-swim", "swimming"), ("person-simple-bike", "cycling"), ("flag-checkered", "race"),
        "golf", "hockey", "volleyball", "timer", ("alarm", "clock"), ("sneaker", "shoes running"),
    ]),
    ("health wellness medical care", [
        ("heartbeat", "cardio"), ("heart", "love"), "first-aid", ("pill", "medicine"),
        ("syringe", "vaccine"), ("stethoscope", "doctor"), "bandaids", "thermometer", ("eye", "vision"),
        ("wind", "breathe"), "bone", ("tooth", "dentist"), ("drop", "water"), ("moon-stars", "sleep night"),
        ("leaf", "calm"), ("person-arms-spread", "yoga meditation"),
    ]),
    ("food drink cooking eat recipes", [
        ("coffee", "cafe"), "coffee-bean", "beer-bottle", "wine", "pizza", ("hamburger", "burger"),
        ("bread", "bakery"), "cookie", "ice-cream", ("cooking-pot", "kitchen"),
        ("fork-knife", "restaurant dinner"), ("knife", "kitchen"), "egg", ("carrot", "vegetables"),
        ("cherries", "fruit"), ("avocado", "fruit"), "popcorn", ("martini", "cocktail bar"), "bowl-food",
    ]),
    ("shopping shop store buy retail", [
        ("shopping-cart", "groceries"), ("shopping-cart-simple", "groceries"), "storefront", "basket",
        "handbag", ("t-shirt", "clothes fashion"), "watch", ("diamond", "jewelry"),
        ("package", "delivery parcel"), ("truck", "delivery"), "barcode",
    ]),
    ("social chat friends communication people", [
        ("chat-circle", "message"), ("chats", "messages"), ("chat-teardrop-text", "message"), "users",
        "users-four", ("heart-straight", "love"), ("hand-waving", "hello"), ("hand-heart", "charity"),
        ("thumbs-up", "like"), ("megaphone-simple", "marketing announce"), ("at", "email mention"),
        ("share-network", "share"), ("rocket-launch", "startup launch"),
    ]),
    ("nature outdoors weather garden", [
        "tree-evergreen", ("tree-palm", "beach"), ("flower-tulip", "spring"), ("sun", "summer day"),
        ("moon", "night"), "cloud", ("cloud-rain", "rain"), ("snowflake", "winter snow"), "rainbow",
        ("fish", "animal"), ("bird", "animal"), ("butterfly", "animal"), ("cat", "animal pet"),
        ("dog", "animal pet"), ("horse", "animal"), ("paw-print", "animal pet"), ("waves", "sea ocean"),
        ("drop-half", "water"), ("grains", "farm"),
    ]),
    ("creative art design draw", [
        ("palette", "colors paint"), ("paint-brush", "paint"), ("paint-bucket", "paint"), "pencil",
        ("scissors", "crafts"), ("sketch-logo", "diamond"), "shapes", ("star", "favorite"),
        ("sparkle", "ai magic"), ("magic-wand", "magic"), ("image", "photo picture"),
        ("frame-corners", "photo"),
    ]),
    ("misc symbol tools", [
        ("lightning", "power energy"), "fire", "flame", "anchor", ("hourglass", "time"), "infinity",
        ("gear-six", "settings"), ("wrench", "repair"), ("hammer", "build diy"), "toolbox",
        "diamonds-four", "square-logo", "circle-dashed", "hexagon", "triangle",
        ("seal-check", "verified"), ("bookmark-simple", "saved"), "flag-pennant", ("push-pin", "pinned"),
    ]),
]


def index():
    """[(name, keywords)] in picker order, each name once with all its keywords."""
    entries = {}
    for shared, icons in GROUPS:
        for icon in icons:
            name, own = icon if isinstance(icon, tuple) else (icon, "")
            words = entries.setdefault(name, [])
            for word in f"{own} {shared}".split():
                if word not in words and word not in name.split("-"):
                    words.append(word)
    return list(entries.items())


def main():
    entries = index()
    INDEX.write_text("".join(f"{name}\t{' '.join(words)}\n" for name, words in entries))
    missing = [name for name, _ in entries if not (ICONS / f"{name}.svg").exists()]
    if missing:
        with urllib.request.urlopen(PACKAGE) as response:
            archive = tarfile.open(fileobj=io.BytesIO(response.read()), mode="r:gz")
        regular = {Path(m.name).stem: m for m in archive.getmembers() if m.isfile() and m.name.endswith(".svg") and "/regular/" in m.name}
        unknown = [name for name in missing if name not in regular]
        if unknown:
            sys.exit(f"not in Phosphor: {', '.join(unknown)}")
        for name in missing:
            (ICONS / f"{name}.svg").write_bytes(archive.extractfile(regular[name]).read())
    added = sum((ICONS / f"{name}.svg").stat().st_size for name in missing)
    print(f"{len(entries)} icons, {len(missing)} added ({added / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
