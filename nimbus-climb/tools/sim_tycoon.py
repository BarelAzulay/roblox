#!/usr/bin/env python3
"""Nimbus Climb: tycoon economy simulation (ARCHITECTURE_V3.md "Phase 2: Tycoon homes").

HOW TO RUN (from the repo root; Python 3.8+, no packages needed for the simulation itself)
    python3 tools/sim_tycoon.py                  timeline of one typical player + Monte Carlo + target check
    python3 tools/sim_tycoon.py --seed 7         another typical player (different roulette luck)
    python3 tools/sim_tycoon.py --runs 6         follow 6 prestiges in the timeline
    python3 tools/sim_tycoon.py --no-pets        worst case: the player never gets an Economy pet
    python3 tools/sim_tycoon.py --mc 400         Monte Carlo size (default 200 players)
    python3 tools/sim_tycoon.py --quiet          summary only (no purchase-by-purchase timeline)
    python3 tools/sim_tycoon.py --check          compare the constants below with src/shared/TycoonCatalog.lua and
                                                 run its Validate() (needs `pip install lupa`)
    python3 tools/sim_tycoon.py --plan plan.png  draw the yard layout of TycoonCatalog.lua from above (lupa + Pillow)
Exit status 1 when a target is missed (or --check finds a difference).

WHAT IT SIMULATES (one second per step)
  * An ACTIVE player claims a home at t = 0 with 0 Cash, banks the Collector every COLLECT_EVERY seconds and spends
    BUY_OVERHEAD seconds walking to each pad.
  * Buying: the player picks the best-value pad (income gained per Cash; a pad without income counts as a small
    share of the current income, a new house as HOUSE_WEIGHT of it) among the pads it could afford within
    PATIENCE seconds, saves for it, and meanwhile buys any affordable pad that costs at most FILLER of that target.
    When the next house waits for Home Level, or the Sky Castle waits for Home Level 40, every level gets a bonus.
  * Pets: roulette rolls on a schedule (ROLLS: the tutorial rolls, then roughly one roll every 15-30 min from the
    obby), each with the real odds of Config.Roulettes and the real pets of PetCatalog: an Economy pet is placed in
    the Garden (best incomes first, up to the Garden's slots), a Combat pet earns nothing here.
  * Kitchen: while the Kitchen is idle the player cooks the food with the best XP per Cash (when it beats the pads)
    and feeds it to the garden pet that gains the most income per XP (pet income +10% per level).
  * Prestige as soon as the Sky Castle stands and the Home Level is 40: stations reset except the decor (kept), Cash
    resets, pets keep their levels, income x1.25 per star.
  * Offline earnings and the Collector cap are reported (the active player never fills the Collector).

THE CONSTANTS BLOCK below must equal src/shared/TycoonCatalog.lua: tools/smoke_p2_economy.lua (smoke scenario
p2_economy) reads the block and fails on any difference, and `--check` does the same from Python. Tune here, run the
sim, then copy the numbers into the catalog (or the other way round).
"""
import argparse
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ==== BEGIN SIM CONSTANTS ====
# Read by tools/smoke_p2_economy.lua: exactly one `NAME = value` per line, value = a number, a list of numbers or a
# "string"; '#' starts a comment. Station constants are named <KIND>_<StationId>.
# PRICE_<id>: Cash to build / upgrade TO level 1, 2, ...   CAPS_<id>: max level at Cottage, Villa, Manor, Sky Castle
# REQ_<id>: "<stationId>=level ... House=<tier> Prestige=n" (station keys hide the pad until built)
PRICE_Press1 = [0, 60, 160, 500, 2000, 5500, 9000, 20000, 60000, 160000]
PRICE_Press2 = [700, 1800, 4200, 8500, 15000, 22000, 38000, 70000, 150000, 400000]
PRICE_Press3 = [18000, 25000, 36000, 52000, 75000, 105000, 170000, 240000, 640000, 1040000]
PRICE_Press4 = [95000, 175000, 220000, 290000, 370000, 480000, 620000, 800000, 1300000, 1900000]
PRICE_Collector = [0, 6000, 45000, 240000, 800000]
PRICE_Garden = [1500, 12000, 30000, 65000, 170000, 350000, 720000, 1440000]
PRICE_Kitchen = [3500, 35000, 190000, 400000, 1100000]
PRICE_Gym = [14000, 65000, 250000, 540000, 1300000]
PRICE_Vault = [9000, 50000, 220000, 480000, 1200000]
PRICE_House = [300, 24000, 115000, 520000]
PRICE_FusionMachine = [25000, 200000, 800000]
PRICE_ArenaGate = [150000]
PRICE_DecorLamps = [3000, 27000, 210000]
PRICE_DecorFence = [7000, 48000, 290000]
PRICE_DecorFlowers = [4500, 36000, 240000]
PRICE_DecorFountain = [45000, 290000, 880000]
PRICE_DecorBanners = [12000, 65000, 380000]
PRICE_DecorPodium = [9000, 56000, 340000]
CAPS_Press1 = [6, 8, 9, 10]
CAPS_Press2 = [6, 8, 9, 10]
CAPS_Press3 = [0, 6, 8, 10]
CAPS_Press4 = [0, 0, 8, 10]
CAPS_Collector = [2, 3, 4, 5]
CAPS_Garden = [2, 4, 6, 8]
CAPS_Kitchen = [1, 2, 4, 5]
CAPS_Gym = [1, 2, 4, 5]
CAPS_Vault = [1, 2, 4, 5]
CAPS_House = [4, 4, 4, 4]
CAPS_FusionMachine = [1, 2, 3, 3]
CAPS_ArenaGate = [1, 1, 1, 1]
CAPS_DecorLamps = [1, 2, 3, 3]
CAPS_DecorFence = [1, 2, 3, 3]
CAPS_DecorFlowers = [1, 2, 3, 3]
CAPS_DecorFountain = [0, 1, 2, 3]
CAPS_DecorBanners = [1, 2, 3, 3]
CAPS_DecorPodium = [1, 2, 3, 3]
REQ_Press1 = ""
REQ_Press2 = "Press1=2"
REQ_Press3 = "Press2=3 House=Villa"
REQ_Press4 = "Press3=3 House=Manor"
REQ_Collector = "Press1=1"
REQ_Garden = "Press2=2"
REQ_Kitchen = "Garden=1"
REQ_Gym = "Kitchen=1"
REQ_Vault = "Press2=2"
REQ_House = "Collector=1"
REQ_FusionMachine = "Kitchen=1 Prestige=1"
REQ_ArenaGate = "Gym=1"
REQ_DecorLamps = "Collector=1"
REQ_DecorFence = "Press2=2"
REQ_DecorFlowers = "Garden=1"
REQ_DecorFountain = "Kitchen=1 House=Villa"
REQ_DecorBanners = "Vault=1"
REQ_DecorPodium = "Garden=1"
KEEP_ON_PRESTIGE = "DecorLamps DecorFence DecorFlowers DecorFountain DecorBanners DecorPodium"
COMING_SOON = "ArenaGate"
# effects
INCOME_Press1 = [5, 6.5, 8.5, 11, 14.5, 18.5, 24, 31, 41, 53]
INCOME_Press2 = [13, 17, 22, 29, 37, 48, 63, 82, 106, 138]
INCOME_Press3 = [34, 44, 57, 74, 97, 125, 163, 210, 275, 360]
INCOME_Press4 = [88, 114, 149, 193, 250, 325, 425, 550, 715, 930]
COLLECTOR_BONUS = [0, 0.1, 0.2, 0.3, 0.4]
COLLECTOR_CAP_SECONDS = [300, 360, 420, 480, 600]
COLLECTOR_FLAT_CAP = [2000, 6000, 20000, 60000, 150000]
VAULT_CAP_SECONDS = [300, 600, 900, 1200, 1800]
VAULT_FLAT_CAP = [5000, 20000, 60000, 150000, 400000]
VAULT_OFFLINE_PERCENT = [0.1, 0.15, 0.2, 0.25, 0.3]
VAULT_OFFLINE_HOURS = [1, 2, 3, 4, 4]
OFFLINE_MIN_SECONDS = 120
GARDEN_SLOTS = [1, 2, 3, 4, 5, 6, 7, 8]
KITCHEN_SLOTS = [3, 4, 6, 8, 10]
KITCHEN_COOK_SPEED = [1, 1.25, 1.5, 1.75, 2]
GYM_SLOTS = [1, 2, 3, 4, 5]
GYM_XP_PER_MINUTE = [20, 30, 45, 60, 80]
FUSION_TOKEN_DISCOUNT = [0, 0.1, 0.2]
HOUSE_HOME_LEVEL = [0, 10, 20, 30]
PRESTIGE_HOME_LEVEL = 40
PRESTIGE_MULTIPLIER = 1.25
PRESTIGE_GEMS = [100, 10, 25]  # first reward, minus per later star, floor
# foods: Price, Xp, CookSeconds, KitchenLevel
FOOD_Snack = [50, 25, 6, 1]
FOOD_Meal = [600, 150, 20, 2]
FOOD_Feast = [6000, 800, 45, 4]
PET_XP = [50, 20, 1.6, 5]  # MaxLevel, Base, Exponent, Round: XpToNext(L) = round(Base * L ^ Exponent / Round) * Round
TIER_MULTIPLIER = [1, 1.5, 2.5]  # Normal, Golden, Rainbow
# pets (from Config + PetCatalog; the smoke check verifies them): rarity order Common .. Secret
RARITY_SCALE = [1, 1.5, 2.3, 3.5, 5.5, 8.5, 13]
PET_ROLLABLE = [6, 6, 5, 4, 3, 2]  # rollable pets per rarity, Common .. Mythic (Secret pets are not in these roulettes)
ECON_INCOME_Common = [10, 11, 9]  # base Income of the rollable Economy pets of each rarity
ECON_INCOME_Uncommon = [11, 10, 12]
ECON_INCOME_Rare = [12, 11, 10]
ECON_INCOME_Epic = [12, 12]
ECON_INCOME_Legendary = [12]
ECON_INCOME_Mythic = [12]
ODDS_Cloud = [60, 28, 10, 2, 0, 0]  # Config.Roulettes weights, Common .. Mythic
ODDS_Storm = [0, 35, 40, 20, 5, 0]
ODDS_Sky = [0, 0, 35, 45, 17, 3]
ODDS_Celestial = [0, 0, 0, 45, 40, 15]
# ==== END SIM CONSTANTS ====

STATION_ORDER = [
    "Press1", "Press2", "Press3", "Press4", "Collector", "Garden", "Kitchen", "Gym", "Vault", "House",
    "FusionMachine", "ArenaGate", "DecorLamps", "DecorFence", "DecorFlowers", "DecorFountain", "DecorBanners", "DecorPodium",
]
KIND = {
    "Press1": "Press", "Press2": "Press", "Press3": "Press", "Press4": "Press", "Collector": "Collector",
    "Garden": "Garden", "Kitchen": "Kitchen", "Gym": "Gym", "Vault": "Vault", "House": "House",
    "FusionMachine": "Fusion", "ArenaGate": "Arena",
}
TIERS = ["Cottage", "Villa", "Manor", "SkyCastle"]
TIER_NAMES = ["Cottage", "Villa", "Manor", "Sky Castle"]
RARITIES = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"]
FOODS = ["Snack", "Meal", "Feast"]

# ---- the player model (assumptions, not catalog data) ----
COLLECT_EVERY = 20  # seconds between Collector visits
BUY_OVERHEAD = 4  # seconds to walk to a pad and hold E
PATIENCE = 300  # seconds of income the player is willing to save for one target
FILLER = 0.3  # while saving, buy any affordable pad costing at most this share of the target
HOUSE_WEIGHT = 0.3  # a new house is worth this share of the current income per second
CHORE_WEIGHT = 0.03  # a pad without income (decor, gym, vault...) is worth this share
KITCHEN_WEIGHT = 0.08  # the first Kitchen (feeding unlocks)
HL_PUSH = 0.2  # extra share for any level while the next house waits for Home Level
# roulette rolls: (minutes after the first claim, roulette). The tutorial gives one Cloud roll and its match pays
# another; afterwards an obby run every ~15-30 minutes buys a roll (Storm / Sky as the token income grows).
ROLLS = [(0, "Cloud"), (0, "Cloud"), (12, "Cloud"), (25, "Cloud"), (40, "Cloud"), (55, "Storm"), (75, "Cloud"),
         (95, "Storm"), (115, "Cloud"), (135, "Storm"), (160, "Storm"), (190, "Sky"), (220, "Storm"), (250, "Sky"),
         (280, "Storm"), (320, "Sky"), (360, "Storm"), (400, "Sky"), (440, "Storm"), (480, "Sky"), (540, "Sky"),
         (600, "Celestial"), (660, "Sky"), (720, "Celestial")]

# ---- targets (ARCHITECTURE_V3.md Phase 2 + the economy brief) ----
TARGETS = dict(
    first_purchase_s=30,  # every player
    early_mean_gap_min=(0.5, 3.0),  # median player, first 30 minutes
    early_p90_gap_min=3.0,  # 90% of the first-30-minute gaps of the median player
    villa_min=(25, 40),  # Monte Carlo median
    prestige1_min=(120, 180),  # Monte Carlo median ("about 2-3 hours of active play")
    dead_time_min=6.0,  # longest stretch with NOTHING affordable, every player incl. no Economy pets
    no_pet_prestige1_min=240,  # even without Economy pets the first prestige comes
)


# ------------------------------------------------------------------------------------------------
# catalog model
# ------------------------------------------------------------------------------------------------
def parse_req(text):
    out = {}
    for tok in text.split():
        k, v = tok.split("=")
        out[k] = v if k == "House" else int(v)
    return out


class Station:
    def __init__(self, sid):
        g = globals()
        self.id = sid
        self.kind = KIND.get(sid, "Decor")
        self.price = list(g["PRICE_" + sid])
        self.max = len(self.price)
        self.caps = list(g["CAPS_" + sid])
        self.req = parse_req(g["REQ_" + sid])
        self.keep = sid in KEEP_ON_PRESTIGE.split()
        self.soon = sid in COMING_SOON.split()
        self.income = list(g.get("INCOME_" + sid, []))


STATIONS = {sid: Station(sid) for sid in STATION_ORDER}
FOOD = {f: dict(zip(["price", "xp", "cook", "kitchen"], globals()["FOOD_" + f])) for f in FOODS}


def xp_to_next(level):
    max_level, base, exp, rnd = PET_XP
    if level >= max_level:
        return math.inf
    return max(rnd, int(math.floor(base * level ** exp / rnd + 0.5)) * rnd)


def tier_of(st):
    return max(1, st.get("House", 0))


def home_level(st):
    return sum(v for k, v in st.items() if k in STATIONS)


def press_income(st):
    c = st.get("Collector", 0)
    if c < 1:
        return 0.0
    total = 0.0
    for sid in ("Press1", "Press2", "Press3", "Press4"):
        lv = st.get(sid, 0)
        if lv:
            total += STATIONS[sid].income[lv - 1]
    return total * (1 + COLLECTOR_BONUS[c - 1])


def pet_income(p):
    return p["base"] * RARITY_SCALE[RARITIES.index(p["rarity"])] * (1 + 0.1 * (p["level"] - 1))


def garden(st, pets):
    slots = GARDEN_SLOTS[st["Garden"] - 1] if st.get("Garden", 0) else 0
    return sorted(pets, key=lambda p: -pet_income(p))[:slots]


def income(st, pets, stars):
    if st.get("Collector", 0) < 1:
        return 0.0
    return (press_income(st) + sum(pet_income(p) for p in garden(st, pets))) * PRESTIGE_MULTIPLIER ** stars


def collector_cap(st, stars, pets=()):
    """TycoonCatalog.CollectorCap(home) without the optional income: presses + the garden pets at level 1."""
    c = st.get("Collector", 0)
    if c < 1:
        return 0
    flat, secs = COLLECTOR_FLAT_CAP[c - 1], COLLECTOR_CAP_SECONDS[c - 1]
    v = st.get("Vault", 0)
    if v:
        flat += VAULT_FLAT_CAP[v - 1]
        secs += VAULT_CAP_SECONDS[v - 1]
    level1 = sum(p["base"] * RARITY_SCALE[RARITIES.index(p["rarity"])] for p in garden(st, pets))
    return math.floor(flat + secs * (press_income(st) + level1) * PRESTIGE_MULTIPLIER ** stars)


def offline_earnings(st, seconds, inc):
    v = st.get("Vault", 0)
    if v < 1 or seconds < OFFLINE_MIN_SECONDS:
        return 0
    return math.floor(inc * min(seconds, VAULT_OFFLINE_HOURS[v - 1] * 3600) * VAULT_OFFLINE_PERCENT[v - 1])


def pads(st, stars):
    """[(id, nextLevel, price, lockReason|None)] exactly like TycoonCatalog.AvailablePads (without the prestige pad)."""
    hl = home_level(st)
    tier = tier_of(st)
    out = []
    for sid in STATION_ORDER:
        s = STATIONS[sid]
        lv = st.get(sid, 0)
        if lv >= s.max:
            continue
        if any(k in STATIONS and k != "House" and st.get(k, 0) < v for k, v in s.req.items()):
            continue
        nxt = lv + 1
        lock = None
        if s.soon:
            lock = "Coming soon"
        elif s.req.get("Prestige", 0) > stars:
            lock = "Unlocks at Prestige %d" % s.req["Prestige"]
        elif "House" in s.req and TIERS.index(s.req["House"]) + 1 > tier:
            lock = "Needs the " + TIER_NAMES[TIERS.index(s.req["House"])]
        elif sid == "House" and HOUSE_HOME_LEVEL[nxt - 1] > hl:
            lock = "Reach Home Level %d" % HOUSE_HOME_LEVEL[nxt - 1]
        elif nxt > s.caps[tier - 1]:
            lock = "Needs the " + next(TIER_NAMES[i] for i in range(4) if s.caps[i] >= nxt)
        out.append((sid, nxt, s.price[nxt - 1], lock))
    return out


# ------------------------------------------------------------------------------------------------
# pets
# ------------------------------------------------------------------------------------------------
def roll(rng, roulette):
    weights = globals()["ODDS_" + roulette]
    r = rng.random() * sum(weights)
    rarity = RARITIES[0]
    for i, w in enumerate(weights):
        r -= w
        if r < 0:
            rarity = RARITIES[i]
            break
    pick = rng.randrange(PET_ROLLABLE[RARITIES.index(rarity)])
    econ = globals()["ECON_INCOME_" + rarity]
    if pick < len(econ):
        return {"rarity": rarity, "base": econ[pick], "level": 1, "xp": 0}
    return None  # a Combat pet: trains in the Gym, earns no Cash


# ------------------------------------------------------------------------------------------------
# the simulation
# ------------------------------------------------------------------------------------------------
class Result:
    def __init__(self):
        self.log = []  # (t, text, price, income, homeLevel, run)
        self.milestones = {}  # name -> seconds (since the run start for house tiers / runs, absolute for P<n>)
        self.gaps = []  # (gap seconds, t, id, level, run, t_in_run)
        self.dead = (0, 0)  # longest stretch with nothing affordable: (seconds, t)
        self.food_spent = 0
        self.pets = []
        self.cap_ratio_min = math.inf  # smallest Collector cap / income (seconds) at a purchase
        self.cap_hits = 0
        self.income_at = {}  # minute -> income (first run)


def simulate(seed=1, runs=3, pets_mode="random", max_minutes=900):
    rng = random.Random(seed)
    res = Result()
    t = 0
    stars = 0
    st = {}
    cash = 0.0
    coll = 0.0
    pets = []
    roll_i = 0
    run = 0
    run_start = 0
    last_buy = 0
    food_done_at = 0
    food_xp = None
    next_collect = 3  # the player walks from the gate to the first pad
    dead_start = None
    cache_key = None
    cheapest = math.inf
    inc = 0.0
    cap = 0
    dirty = True
    while t < max_minutes * 60 and run < runs:
        while roll_i < len(ROLLS) and ROLLS[roll_i][0] * 60 <= t:
            if pets_mode == "random":
                p = roll(rng, ROLLS[roll_i][1])
                if p:
                    pets.append(p)
                    dirty = True
            roll_i += 1
        if dirty:
            inc = income(st, pets, stars)
            cap = collector_cap(st, stars, pets)
            dirty = False
        if run == 0 and t % 60 == 0:
            res.income_at[t // 60] = inc
        coll = min(cap, coll + inc)
        if coll >= cap and cap > 0 and inc > 0:
            res.cap_hits += 1
        t += 1
        if food_xp and t >= food_done_at:
            g = garden(st, pets)
            if g:
                best = max(g, key=lambda p: p["base"] * RARITY_SCALE[RARITIES.index(p["rarity"])] / xp_to_next(p["level"]))
                best["xp"] += food_xp
                while best["xp"] >= xp_to_next(best["level"]):
                    best["xp"] -= xp_to_next(best["level"])
                    best["level"] += 1
                dirty = True
            food_xp = None
        key = (tuple(sorted(st.items())), stars)
        if key != cache_key:
            cache_key = key
            cheapest = min([p[2] for p in pads(st, stars) if p[3] is None] or [math.inf])
        if cheapest < math.inf and cheapest > cash + coll:
            if dead_start is None:
                dead_start = t
        elif dead_start is not None:
            if t - dead_start > res.dead[0]:
                res.dead = (t - dead_start, t)
            dead_start = None
        if t < next_collect:
            continue
        next_collect = t + COLLECT_EVERY
        cash += coll
        coll = 0
        while True:
            hl = home_level(st)
            if tier_of(st) >= 4 and hl >= PRESTIGE_HOME_LEVEL:
                stars += 1
                run += 1
                res.milestones["P%d" % stars] = t
                res.milestones["run%d" % stars] = t - run_start
                res.log.append((t, "PRESTIGE -> %d stars (this run %s, Home Level %d)" % (stars, fmt(t - run_start), hl), 0, inc, hl, run - 1))
                run_start = t
                st = {k: v for k, v in st.items() if STATIONS[k].keep}
                cash = 0
                coll = 0
                last_buy = t
                dirty = True
                break
            open_pads = [p for p in pads(st, stars) if p[3] is None]
            if not open_pads:
                break
            cur = max(income(st, pets, stars), 1.0)
            reach = [p for p in open_pads if p[2] - cash <= PATIENCE * cur] or [min(open_pads, key=lambda p: p[2])]
            push = HOUSE_HOME_LEVEL[min(st.get("House", 0), 3)] > hl if st.get("House", 0) < 4 else hl < PRESTIGE_HOME_LEVEL
            best, best_score = None, -1.0
            for sid, lvl, price, _ in reach:
                st2 = dict(st)
                st2[sid] = lvl
                gain = income(st2, pets, stars) - cur
                kind = STATIONS[sid].kind
                if kind == "House":
                    value = cur * HOUSE_WEIGHT
                elif gain > 1e-9:
                    value = gain
                elif kind == "Kitchen" and lvl == 1:
                    value = cur * KITCHEN_WEIGHT
                else:
                    value = cur * CHORE_WEIGHT
                if push:
                    value += cur * HL_PUSH
                score = value / max(price, 1)
                if score > best_score:
                    best, best_score = (sid, lvl, price), score
            kl = st.get("Kitchen", 0)
            if kl and food_xp is None:
                g = garden(st, pets)
                if g:
                    bp = max(g, key=lambda p: p["base"] * RARITY_SCALE[RARITIES.index(p["rarity"])] / xp_to_next(p["level"]))
                    per_level = 0.1 * bp["base"] * RARITY_SCALE[RARITIES.index(bp["rarity"])] * PRESTIGE_MULTIPLIER ** stars
                    for f in FOODS:
                        food = FOOD[f]
                        if kl >= food["kitchen"] and food["price"] <= cash:
                            score = per_level * food["xp"] / xp_to_next(bp["level"]) / food["price"]
                            if score > best_score:
                                best, best_score = ("FOOD", f, food["price"]), score
            if best and best[0] != "FOOD" and best[2] > cash:
                fillers = [p for p in open_pads if p[2] <= best[2] * FILLER and p[2] <= cash]
                if fillers:
                    f = min(fillers, key=lambda p: p[2])
                    best = (f[0], f[1], f[2])
            if not best or best[2] > cash:
                break
            if best[0] == "FOOD":
                food = FOOD[best[1]]
                cash -= food["price"]
                res.food_spent += food["price"]
                food_xp = food["xp"]
                food_done_at = t + food["cook"] / KITCHEN_COOK_SPEED[kl - 1]
                continue
            sid, lvl, price = best
            cash -= price
            st[sid] = lvl
            t += BUY_OVERHEAD
            dirty = True
            res.gaps.append((t - last_buy, t, sid, lvl, run, t - run_start))
            last_buy = t
            new_inc = income(st, pets, stars)
            if new_inc > 0:
                res.cap_ratio_min = min(res.cap_ratio_min, collector_cap(st, stars, pets) / max(new_inc, 1e-9))
            res.log.append((t, "%s L%d" % (sid, lvl), price, new_inc, home_level(st), run))
            if sid == "House":
                res.milestones["%s%d" % (TIERS[lvl - 1], run)] = t - run_start
            if "first" not in res.milestones:
                res.milestones["first"] = t
    res.pets = pets
    res.stars = stars
    res.final_stations = st
    return res


# ------------------------------------------------------------------------------------------------
# reporting
# ------------------------------------------------------------------------------------------------
def fmt(seconds):
    s = int(round(seconds))
    if s >= 3600:
        return "%d:%02d:%02d" % (s // 3600, (s % 3600) // 60, s % 60)
    return "%d:%02d" % (s // 60, s % 60)


def money(n):
    return "{:,}".format(int(n))


def pct(values, q):
    v = sorted(values)
    if not v:
        return float("nan")
    i = min(len(v) - 1, max(0, int(round(q * (len(v) - 1)))))
    return v[i]


def early_gaps(res):
    return [g[0] for g in res.gaps if g[4] == 0 and g[5] <= 30 * 60]


def print_timeline(res):
    run = -1
    for (t, text, price, inc, hl, r) in res.log:
        if r != run:
            run = r
            print("\n  -- run %d --" % (run + 1))
        print("  %9s  %-50s %12s   %9.1f Cash/s   Home Level %d" % (fmt(t), text, money(price) if price else "", inc, hl))


def summary_line(res):
    ms = res.milestones
    parts = ["first purchase %s" % fmt(ms.get("first", 0))]
    for name in ("Villa0", "Manor0", "SkyCastle0"):
        if name in ms:
            parts.append("%s %s" % (name[:-1], fmt(ms[name])))
    for i in range(1, 10):
        if "run%d" % i in ms:
            parts.append("prestige %d after %s" % (i, fmt(ms["run%d" % i])))
    return "; ".join(parts)


def offline_table():
    rows = []
    for v in range(1, len(VAULT_OFFLINE_HOURS) + 1):
        st = {"Collector": 1, "Vault": v}
        cells = []
        for hours in (1, 4, 12):
            got = offline_earnings(st, hours * 3600, 1.0)  # in seconds of income at 1 Cash/s
            cells.append("%3d min" % round(got / 60))
        rows.append("    Vault L%d (%2d%% for up to %dh): away 1h -> %s, 4h -> %s, 12h -> %s of active income"
                    % (v, VAULT_OFFLINE_PERCENT[v - 1] * 100, VAULT_OFFLINE_HOURS[v - 1], cells[0], cells[1], cells[2]))
    return rows


def run_report(args):
    failures = []

    def check(ok, text):
        print("  [%s] %s" % ("ok" if ok else "MISSED", text))
        if not ok:
            failures.append(text)

    pets_mode = "none" if args.no_pets else "random"
    main = simulate(seed=args.seed, runs=args.runs, pets_mode=pets_mode)
    if not args.quiet:
        print("Timeline of one %s player (seed %d), %d prestige run(s):" % ("pet-less" if args.no_pets else "typical", args.seed, args.runs))
        print_timeline(main)
        print("\n  pets owned at the end: %s" % (", ".join("%s L%d" % (p["rarity"], p["level"]) for p in main.pets) or "none"))
        print("  Cash spent on pet food: %s" % money(main.food_spent))
    print("\nThis player: " + summary_line(main))

    # Monte Carlo over pet luck
    n = args.mc
    ms = {}
    early_mean, early_p90, dead, caps, cap_hits = [], [], [], [], 0
    runs_needed = 3
    for seed in range(1000, 1000 + n):
        r = simulate(seed=seed, runs=runs_needed)
        for k, v in r.milestones.items():
            ms.setdefault(k, []).append(v)
        eg = early_gaps(r)
        early_mean.append(sum(eg) / len(eg) if eg else 1e9)
        early_p90.append(pct(eg, 0.9) if eg else 1e9)
        dead.append(r.dead[0])
        caps.append(r.cap_ratio_min)
        cap_hits += r.cap_hits
    print("\nMonte Carlo: %d typical players (roulette luck varies), 3 prestige runs each" % n)
    labels = [("first", "first purchase"), ("Cottage0", "Cottage built"), ("Villa0", "Villa"), ("Manor0", "Manor"),
              ("SkyCastle0", "Sky Castle"), ("run1", "1st prestige"), ("run2", "2nd prestige run"), ("run3", "3rd prestige run")]
    for key, label in labels:
        v = ms.get(key, [])
        if v:
            print("  %-18s p10 %9s   median %9s   p90 %9s   (%d players)" % (label, fmt(pct(v, 0.1)), fmt(pct(v, 0.5)), fmt(pct(v, 0.9)), len(v)))
    print("  early purchase gap (first 30 min): median player mean %.2f min, 90th pct gap %.2f min"
          % (pct(early_mean, 0.5) / 60, pct(early_p90, 0.5) / 60))
    print("  longest stretch with nothing affordable: median %.1f min, worst %.1f min" % (pct(dead, 0.5) / 60, max(dead) / 60))
    print("  Collector cap at purchases: at least %.1f min of income (the active player banks every %d s)" % (min(caps) / 60, COLLECT_EVERY))

    nopet = simulate(seed=1, runs=2, pets_mode="none")
    print("\nWorst case, no Economy pet ever: " + summary_line(nopet))
    print("  longest stretch with nothing affordable: %.1f min" % (nopet.dead[0] / 60))

    print("\nOffline earnings (the Vault; 0 without one, nothing for absences under %d s):" % OFFLINE_MIN_SECONDS)
    for row in offline_table():
        print(row)
    longest = simulate(seed=args.seed, runs=8, max_minutes=2400)
    print("\nLater prestiges (seed %d): %s" % (args.seed, ", ".join(
        "P%d %s" % (i, fmt(longest.milestones["run%d" % i])) for i in range(1, 9) if "run%d" % i in longest.milestones)))

    print("\nTargets:")
    firsts = ms.get("first", [])
    check(firsts and max(firsts) <= TARGETS["first_purchase_s"], "first purchase within %d s of claiming (worst %s)" % (TARGETS["first_purchase_s"], fmt(max(firsts or [0]))))
    lo, hi = TARGETS["early_mean_gap_min"]
    em = pct(early_mean, 0.5) / 60
    check(lo <= em <= hi, "a new purchase every 1-3 minutes early on (median player: mean gap %.2f min in the first 30 min)" % em)
    ep = pct(early_p90, 0.5) / 60
    check(ep <= TARGETS["early_p90_gap_min"], "early gaps stay short (90%% of first-30-min gaps <= %.1f min: %.2f min)" % (TARGETS["early_p90_gap_min"], ep))
    villa = pct(ms.get("Villa0", [0]), 0.5) / 60
    lo, hi = TARGETS["villa_min"]
    check(lo <= villa <= hi, "Villa around %d-%d min (median %.1f min)" % (lo, hi, villa))
    p1 = pct(ms.get("run1", [1e9]), 0.5) / 60
    lo, hi = TARGETS["prestige1_min"]
    check(lo <= p1 <= hi, "first Prestige after about 2-3 hours (median %.0f min)" % p1)
    r2 = pct(ms.get("run2", [1e9]), 0.5) / 60
    r3 = pct(ms.get("run3", [1e9]), 0.5) / 60
    check(r2 < p1 and r3 < r2, "later prestiges faster (median runs %.0f -> %.0f -> %.0f min)" % (p1, r2, r3))
    worst_dead = max(max(dead), nopet.dead[0]) / 60
    check(worst_dead <= TARGETS["dead_time_min"], "never more than %d min with nothing to buy (worst %.1f min, pet-less player included)" % (TARGETS["dead_time_min"], worst_dead))
    np1 = nopet.milestones.get("run1", 1e9) / 60
    check(np1 <= TARGETS["no_pet_prestige1_min"], "no dead end: a player without Economy pets still prestiges (%.0f min)" % np1)
    check(min(caps) >= 120 and cap_hits == 0, "the Collector never fills up for an active player (cap >= 2 min of income at every purchase: %.1f min; seconds spent full: %d)" % (min(caps) / 60, cap_hits))
    offline_max = max(offline_earnings({"Collector": 1, "Vault": v}, 48 * 3600, 1.0) for v in range(1, 6)) / 3600
    check(0 < offline_max <= 2.0, "offline earnings meaningful but capped (best Vault, any absence: %.1f h of active income)" % offline_max)
    print("\n%s" % ("ALL TARGETS MET" if not failures else "%d TARGET(S) MISSED" % len(failures)))
    return 0 if not failures else 1


# ------------------------------------------------------------------------------------------------
# --check / --plan: load the Lua catalog with lupa and tiny Roblox stand-ins
# ------------------------------------------------------------------------------------------------
LUA_STUBS = r"""
local function vec(x, y, z) return setmetatable({X = x, Y = y, Z = z}, VecMT) end
VecMT = {
  __add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
  __sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
  __mul = function(a, b) if type(a) == "number" then return vec(a * b.X, a * b.Y, a * b.Z) end
                         if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
                         return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z) end,
  __index = function(v, k) if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end end,
}
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
-- CFrames are position + yaw (the catalog only turns about Y)
local function rot(yaw, x, z) local c, s = math.cos(yaw), math.sin(yaw) return x * c + z * s, -x * s + z * c end
local function cf(x, y, z, yaw) return setmetatable({x = x, y = y, z = z, yaw = yaw or 0}, CfMT) end
CfMT = {
  __mul = function(a, b)
    if getmetatable(b) == VecMT then local rx, rz = rot(a.yaw, b.X, b.Z) return vec(a.x + rx, a.y + b.Y, a.z + rz) end
    local rx, rz = rot(a.yaw, b.x, b.z) return cf(a.x + rx, a.y + b.y, a.z + rz, a.yaw + b.yaw)
  end,
  __index = function(c, k)
    if k == "Position" then return vec(c.x, c.y, c.z) end
    if k == "LookVector" then local x, z = rot(c.yaw, 0, -1) return vec(x, 0, z) end
    if k == "Yaw" then return c.yaw end
  end,
}
CFrame = {
  new = function(x, y, z) if type(x) == "table" then return cf(x.X, x.Y, x.Z, 0) end return cf(x or 0, y or 0, z or 0, 0) end,
  Angles = function(rx, ry, rz) return cf(0, 0, 0, ry or 0) end,
  lookAt = function(a, b) local dx, dz = b.X - a.X, b.Z - a.Z return cf(a.X, a.Y, a.Z, math.atan2(-dx, -dz)) end,
}
local colorMT = {}
Color3 = { fromRGB = function(r, g, b) return setmetatable({R = r / 255, G = g / 255, B = b / 255}, colorMT) end,
           new = function(r, g, b) return setmetatable({R = r, G = g, B = b}, colorMT) end }
function typeof(v)
  local mt = getmetatable(v)
  if mt == VecMT then return "Vector3" elseif mt == CfMT then return "CFrame" elseif mt == colorMT then return "Color3" end
  return type(v)
end
warn = function() end
"""


def load_catalog():
    import importlib

    runtime = None
    for name in ("lupa.luajit21", "lupa.luajit20", "lupa.lua51", "lupa"):  # Lua 5.1 semantics first, like smoke.py
        try:
            runtime = importlib.import_module(name).LuaRuntime
            break
        except (ImportError, AttributeError):
            continue
    if runtime is None:
        sys.exit("--check / --plan need lupa:  pip install lupa")
    rt = runtime(unpack_returned_tuples=True)
    rt.execute("math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end")
    rt.execute(LUA_STUBS)
    g = rt.globals()
    shared = os.path.join(ROOT, "src", "shared")
    g.CONFIG_SRC = open(os.path.join(shared, "Config.lua"), encoding="utf-8").read()
    g.CATALOG_SRC = open(os.path.join(shared, "TycoonCatalog.lua"), encoding="utf-8").read()
    rt.execute(r"""
      local load_ = loadstring or load
      local Config = assert(load_(CONFIG_SRC, "=Config"))()
      local Shared = { Config = "Config", FindFirstChild = function() return nil end }
      script = { Parent = Shared }
      require = function(m) if m == "Config" then return Config end error("no module " .. tostring(m)) end
      CATALOG = assert(load_(CATALOG_SRC, "=TycoonCatalog"))()
    """)
    return rt, g.CATALOG


def lua_list(t):
    out = []
    i = 1
    while t[i] is not None:
        out.append(t[i])
        i += 1
    return out


def run_check():
    rt, cat = load_catalog()
    problems = []

    def same(name, a, b):
        if isinstance(a, list) and isinstance(b, list):
            def eq(x, y):
                if isinstance(x, (int, float)) and isinstance(y, (int, float)):
                    return abs(float(x) - float(y)) < 1e-9
                return x == y
            ok = len(a) == len(b) and all(eq(x, y) for x, y in zip(a, b))
        else:
            ok = a == b
        if not ok:
            problems.append("%s: sim %r, catalog %r" % (name, a, b))

    by_id = cat.ById
    order = lua_list(cat.Order)
    same("station order", STATION_ORDER, order)
    for sid in STATION_ORDER:
        d = by_id[sid]
        if d is None:
            problems.append("catalog has no " + sid)
            continue
        s = STATIONS[sid]
        same("PRICE_" + sid, s.price, lua_list(d.Price))
        same("CAPS_" + sid, s.caps, [d.TierCaps[t] for t in TIERS])
        req = {}
        for k, v in d.Requires.items():
            req[k] = v
        same("REQ_" + sid, s.req, req)
        same("KEEP " + sid, s.keep, bool(d.KeepOnPrestige))
        same("COMING_SOON " + sid, s.soon, bool(d.ComingSoon))
        if s.kind == "Press":
            same("INCOME_" + sid, s.income, [e.Income for e in lua_list(d.Effects)])
    eff = lambda sid, key: [e[key] for e in lua_list(by_id[sid].Effects)]
    same("COLLECTOR_BONUS", COLLECTOR_BONUS, eff("Collector", "Bonus"))
    same("COLLECTOR_CAP_SECONDS", COLLECTOR_CAP_SECONDS, eff("Collector", "CapSeconds"))
    same("COLLECTOR_FLAT_CAP", COLLECTOR_FLAT_CAP, eff("Collector", "FlatCap"))
    same("VAULT_CAP_SECONDS", VAULT_CAP_SECONDS, eff("Vault", "CapSeconds"))
    same("VAULT_FLAT_CAP", VAULT_FLAT_CAP, eff("Vault", "FlatCap"))
    same("VAULT_OFFLINE_PERCENT", VAULT_OFFLINE_PERCENT, eff("Vault", "OfflinePercent"))
    same("VAULT_OFFLINE_HOURS", VAULT_OFFLINE_HOURS, eff("Vault", "OfflineHours"))
    same("GARDEN_SLOTS", GARDEN_SLOTS, eff("Garden", "Slots"))
    same("KITCHEN_SLOTS", KITCHEN_SLOTS, eff("Kitchen", "Slots"))
    same("KITCHEN_COOK_SPEED", KITCHEN_COOK_SPEED, eff("Kitchen", "CookSpeed"))
    same("GYM_SLOTS", GYM_SLOTS, eff("Gym", "Slots"))
    same("GYM_XP_PER_MINUTE", GYM_XP_PER_MINUTE, eff("Gym", "XpPerMinute"))
    same("FUSION_TOKEN_DISCOUNT", FUSION_TOKEN_DISCOUNT, eff("FusionMachine", "TokenDiscount"))
    same("OFFLINE_MIN_SECONDS", OFFLINE_MIN_SECONDS, cat.OfflineMinSeconds)
    same("HOUSE_HOME_LEVEL", HOUSE_HOME_LEVEL, [t.HomeLevel for t in lua_list(cat.HouseTiers)])
    p = cat.Prestige
    same("PRESTIGE_HOME_LEVEL", PRESTIGE_HOME_LEVEL, p.HomeLevel)
    same("PRESTIGE_MULTIPLIER", PRESTIGE_MULTIPLIER, p.IncomeMultiplier)
    same("PRESTIGE_GEMS", PRESTIGE_GEMS, [p.GemReward, p.GemRewardStep, p.GemRewardMin])
    for f in FOODS:
        food = cat.FoodsById[f]
        same("FOOD_" + f, globals()["FOOD_" + f], [food.Price, food.Xp, food.CookSeconds, food.KitchenLevel])
    px = cat.PetXp
    same("PET_XP", PET_XP, [px.MaxLevel, px.Base, px.Exponent, px.Round])
    tm = cat.TierMultiplier
    same("TIER_MULTIPLIER", TIER_MULTIPLIER, [tm.Normal, tm.Golden, tm.Rainbow])
    for lv in range(1, PET_XP[0] + 1):
        a, b = xp_to_next(lv), cat.XpToNext(lv)
        if a != b:
            problems.append("XpToNext(%d): sim %r, catalog %r" % (lv, a, b))
            break
    # the pads (ids, next levels, prices, lock reasons) the sim player sees == TycoonCatalog.AvailablePads
    rng = random.Random(7)
    lua_home = rt.eval("function(stars) return { Stations = {}, Prestige = stars } end")
    pad_diffs = 0
    for trial in range(400):
        st = {}
        stars = rng.choice([0, 0, 0, 1, 2])
        for sid in STATION_ORDER:
            if rng.random() < 0.7:
                st[sid] = rng.randint(0, STATIONS[sid].max)
        h = lua_home(stars)
        for k, v in st.items():
            h.Stations[k] = v
        want = [(sid, nxt, price, lock) for (sid, nxt, price, lock) in pads(st, stars)]
        got = [(p.StationId, p.NextLevel, p.Price, p.Locked) for p in lua_list(cat.AvailablePads(h)) if p.StationId != "Prestige"]
        if want != got:
            pad_diffs += 1
            if pad_diffs <= 3:
                problems.append("pads differ for %r (stars %d):\n      sim     %r\n      catalog %r" % (st, stars, want, got))
    ok, probs = cat.Validate()
    if not ok:
        for pr in lua_list(probs):
            problems.append("Validate: " + pr)
    if problems:
        print("sim_tycoon --check: %d difference(s)" % len(problems))
        for pr in problems:
            print("  " + pr)
        return 1
    print("sim_tycoon --check: the catalog matches the sim constants (%d stations), AvailablePads matches the sim's pads on 400 random homes, Validate() passes" % len(order))
    return 0


def run_plan(path):
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        sys.exit("--plan needs Pillow:  pip install Pillow")
    rt, cat = load_catalog()
    S = 12  # pixels per stud
    half = cat.Layout.Half
    pad_size = cat.Layout.PadSize
    margin = 70
    size = int(2 * half * S + 2 * margin)
    img = Image.new("RGB", (size, size + 40), (52, 120, 70))
    dr = ImageDraw.Draw(img)

    def font(px):
        for name in ("DejaVuSans-Bold.ttf", "DejaVuSans.ttf"):
            try:
                return ImageFont.truetype(name, px)
            except OSError:
                continue
        return ImageFont.load_default()

    f_small, f_mid, f_big = font(11), font(13), font(18)

    # plot-local (x, z) -> image: the gate (-Z) at the BOTTOM, +X to the right
    def P(x, z):
        return (margin + (x + half) * S, margin + (half - z) * S)

    def rect(x0, x1, z0, z1, **kw):
        a, b = P(x0, z1), P(x1, z0)
        dr.rectangle([a[0], a[1], b[0], b[1]], **kw)

    rect(-half, half, -half, half, fill=(98, 170, 92))
    for i in range(6):  # mowed stripes
        z0 = -half + i * 2 * half / 6
        if i % 2:
            rect(-half, half, z0, z0 + 2 * half / 6, fill=(110, 182, 100))
    # paths
    for p in lua_list(cat.Layout.Paths):
        a, b, w = p.Start, p.Finish, p.Width
        x0, x1 = min(a.X, b.X) - (w / 2 if a.X == b.X else 0), max(a.X, b.X) + (w / 2 if a.X == b.X else 0)
        z0, z1 = min(a.Z, b.Z) - (w / 2 if a.Z == b.Z else 0), max(a.Z, b.Z) + (w / 2 if a.Z == b.Z else 0)
        rect(x0, x1, z0, z1, fill=(196, 188, 170))
    conv = cat.Layout.Conveyor
    w = conv.Width
    rect(conv.Start.X - w / 2, conv.Start.X + w / 2, min(conv.Start.Z, conv.Finish.Z), max(conv.Start.Z, conv.Finish.Z), fill=(70, 70, 82))
    zz = conv.Start.Z
    while zz > conv.Finish.Z + 2:
        cx, cy = P(conv.Start.X, zz)
        dr.polygon([(cx - 6, cy), (cx + 6, cy), (cx, cy + 9)], fill=(240, 220, 120))
        zz -= 4
    # fence + gate
    a, b = P(-half, half), P(half, -half)
    dr.rectangle([a[0], a[1], b[0], b[1]], outline=(110, 80, 50), width=4)
    gw = cat.Layout.GateWidth
    rect(-gw / 2, gw / 2, -half - 0.6, -half + 0.6, fill=(196, 188, 170))
    for s in (-1, 1):
        rect(s * 7.2 - 1.3, s * 7.2 + 1.3, -half - 1.3, -half + 1.3, fill=(150, 150, 160))
    gx, gy = P(0, -half - 3)
    dr.text((gx, gy), "GATE (street side)", fill=(255, 255, 255), font=f_mid, anchor="mt")
    # lobby fixtures: mailbox (outside), podium, spawn
    mx, my = P(-11, -half - 2)
    dr.rectangle([mx - 5, my - 5, mx + 5, my + 5], fill=(200, 200, 210))
    dr.text((mx, my + 8), "mailbox", fill=(255, 255, 255), font=f_small, anchor="mt")
    sp = cat.Layout.Spawn
    sx, sy = P(sp.X, sp.Z)
    dr.ellipse([sx - 6, sy - 6, sx + 6, sy + 6], outline=(255, 255, 255), width=2)
    dr.text((sx + 9, sy), "spawn", fill=(255, 255, 255), font=f_small, anchor="lm")

    palette = {"Press": (120, 170, 230), "Collector": (240, 196, 80), "Garden": (70, 150, 70), "Kitchen": (232, 140, 90),
               "Gym": (200, 90, 90), "Vault": (150, 150, 170), "House": (226, 214, 190), "Fusion": (170, 110, 220),
               "Arena": (210, 70, 70), "Decor": (250, 160, 200)}
    defs = [cat.ById[sid] for sid in lua_list(cat.Order)] + [cat.PrestigePad]
    rect_fn = cat.FootprintRect
    for d in defs:
        slot = d.Slot
        r = rect_fn(slot.CFrame, slot.Footprint)
        col = palette.get(d.Kind, (255, 255, 255))
        if slot.Perimeter:
            a, b = P(r[1] + 0.8, r[4] - 0.8), P(r[2] - 0.8, r[3] + 0.8)
            dr.rectangle([a[0], a[1], b[0], b[1]], outline=col, width=3)
        elif d.Kind == "Prestige":
            pass
        elif slot.Walkable:
            a, b = P(r[1], r[4]), P(r[2], r[3])
            dr.rectangle([a[0], a[1], b[0], b[1]], outline=col, width=2)
        else:
            rect(r[1], r[2], r[3], r[4], fill=col, outline=(40, 40, 40))
        if d.Kind != "Prestige" and not slot.Perimeter:
            c = slot.CFrame.Position
            lk = slot.CFrame.LookVector
            cx, cy = P(c.X, c.Z)
            dr.text((cx - lk.X * 14, cy + lk.Z * 14), d.Id, fill=(20, 20, 20), font=f_mid, anchor="mm")
            # an arrow from the label toward the station's front (its pad side)
            sx0, sy0 = P(c.X + lk.X * 1.2, c.Z + lk.Z * 1.2)
            ex, ey = P(c.X + lk.X * 3.6, c.Z + lk.Z * 3.6)
            dr.line([sx0, sy0, ex, ey], fill=(20, 20, 20), width=3)
            ox, oz = -lk.Z, lk.X  # perpendicular
            h1 = P(c.X + lk.X * 2.6 + ox * 0.8, c.Z + lk.Z * 2.6 + oz * 0.8)
            h2 = P(c.X + lk.X * 2.6 - ox * 0.8, c.Z + lk.Z * 2.6 - oz * 0.8)
            dr.polygon([h1, h2, (ex, ey)], fill=(20, 20, 20))
        # pad
        pc = slot.Pad.Position
        hx, hz = pad_size.X / 2, pad_size.Z / 2
        rect(pc.X - hx, pc.X + hx, pc.Z - hz, pc.Z + hz, fill=(255, 236, 90) if d.Kind != "Prestige" else (255, 140, 40), outline=(90, 70, 10))
        px, py = P(pc.X, pc.Z)
        label = d.Id.replace("Decor", "").replace("Machine", "")[:9]
        dr.text((px, py), label, fill=(30, 30, 30), font=f_small, anchor="mm")
    # reachability
    reach = cat.ReachablePads(1, 1)[0]
    bad = [k for k, v in reach.items() if not v]
    ok, probs = cat.Validate()
    status = "Validate: %s   unreachable pads: %s" % ("ok" if ok else "%d problem(s)" % len(lua_list(probs)), ", ".join(bad) or "none")
    dr.text((margin, size + 8), status, fill=(255, 255, 255), font=f_big)
    dr.text((margin, 18), "Nimbus Climb home yard (TycoonCatalog.Layout, %d x %d studs, 1 stud = %d px)" % (2 * half, 2 * half, S), fill=(255, 255, 255), font=f_big)
    dr.text((margin, 42), "yellow = buy pads, outlined = walk-through decor zones, arrows = station fronts", fill=(230, 240, 230), font=f_mid)
    img.save(path)
    print("wrote %s (%s)" % (path, status))
    if not ok:
        for pr in lua_list(probs):
            print("  " + pr)
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="Nimbus Climb tycoon economy simulation")
    ap.add_argument("--seed", type=int, default=3, help="roulette luck of the timeline player (default 3)")
    ap.add_argument("--runs", type=int, default=3, help="prestige runs in the timeline (default 3)")
    ap.add_argument("--mc", type=int, default=200, help="Monte Carlo players (default 200)")
    ap.add_argument("--no-pets", action="store_true", help="the timeline player never gets an Economy pet")
    ap.add_argument("--quiet", action="store_true", help="no purchase-by-purchase timeline")
    ap.add_argument("--check", action="store_true", help="compare with src/shared/TycoonCatalog.lua (lupa) and Validate()")
    ap.add_argument("--plan", metavar="PNG", help="draw the yard layout of TycoonCatalog.lua")
    args = ap.parse_args()
    if args.check:
        return run_check()
    if args.plan:
        return run_plan(args.plan)
    return run_report(args)


if __name__ == "__main__":
    sys.exit(main())
