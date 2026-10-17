"""Event-only location identities. Legacy text is never geocoded or folded."""
import hashlib
import re
import uuid

UNKNOWN_COUNTRY = "__unknown__"
COUNTRY_NAMES = {"TR": "Türkiye", "ES": "İspanya", "TH": "Tayland", "PL": "Polonya",
                 "US": "Amerika Birleşik Devletleri", "GB": "Birleşik Krallık", "DE": "Almanya",
                 "FR": "Fransa", "IT": "İtalya", "PT": "Portekiz", "NL": "Hollanda",
                 "GR": "Yunanistan", "GE": "Gürcistan", "CY": "Kıbrıs", "VE": "Venezuela"}
# ISO 3166-1 alpha-2 codes; names are display labels, never identifiers.
COUNTRY_CODES = set("AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW".split())


def validate_location(country_code, city_id):
    country = (country_code or "").strip().upper()
    identity = (city_id or "").strip()
    if country and country not in COUNTRY_CODES:
        raise ValueError("Gecersiz ISO ulke kodu")
    if identity and not re.fullmatch(r"[A-Za-z0-9:_./-]{1,128}", identity):
        raise ValueError("Gecersiz sehir kimligi")
    return country, identity


def location_fields(row):
    country = (row.get("country_code") or "").strip().upper()
    name = (row.get("city") or "").strip()
    identity = (row.get("city_id") or "").strip()
    if not identity:
        identity = "text:" + hashlib.md5((country + "\x1f" + name).encode()).hexdigest()
    return {"country_code": country, "city_id": identity, "city": name,
            "legacy_location": not bool(row.get("city_id"))}


def edited_location(existing, city=None, country_code=None, city_id=None):
    country = country_code if country_code is not None else existing.get("country_code") or ""
    changed = (city is not None and city.strip() != (existing.get("city") or "").strip()) or (
        country_code is not None and country.strip().upper() != (existing.get("country_code") or ""))
    identity = city_id if city_id is not None else ("" if changed else existing.get("city_id") or "")
    country, identity = validate_location(country, identity)
    if country and changed and not identity:
        identity = "manual:" + uuid.uuid4().hex
    return country, identity


def location_options(rows):
    countries = {}
    cities = {}
    for row in sorted(rows, key=lambda row: row.get("city") or ""):
        location = location_fields(row)
        # A country is selectable only when at least one current event has a
        # usable city. Do not expose country-only or blank legacy records.
        if not location["city"]:
            continue
        country = location["country_code"]
        key = country or UNKNOWN_COUNTRY
        countries[key] = {"code": key, "name": COUNTRY_NAMES.get(country, country) or "Ülkesi belirtilmemiş"}
        # Country is part of the selection even for provider-scoped IDs.
        cities.setdefault((country, location["city_id"]), location)
    return {"countries": sorted(countries.values(), key=lambda x: x["name"]),
            "cities": sorted(cities.values(), key=lambda x: (x["city"], x["country_code"], x["city_id"]))}


def public_filters(city="", event_kind="", styles=(), country_code="", city_id=""):
    wheres = ["mes.status='approved'", "COALESCE(se.is_active, 1)=1"]
    values = []
    if city.strip():
        wheres.append("LOWER(COALESCE(mes.city,''))=%s")
        values.append(city.strip().lower())
    if country_code:
        wheres.append("COALESCE(mes.country_code,'')=%s")
        values.append("" if country_code == UNKNOWN_COUNTRY else country_code.strip().upper())
    if city_id:
        wheres.append("COALESCE(NULLIF(mes.city_id,''), 'text:' || md5(COALESCE(mes.country_code,'') || chr(31) || btrim(COALESCE(mes.city,''))))=%s")
        values.append(city_id)
    if event_kind and event_kind != "all":
        wheres.append("LOWER(COALESCE(mes.event_kind,''))=%s")
        values.append(event_kind.strip().lower())
    if styles:
        wheres.append("(" + " OR ".join("(',' || LOWER(COALESCE(mes.dance_styles,'')) || ',') LIKE %s" for _ in styles) + ")")
        values.extend(f"%,{style},%" for style in styles)
    return wheres, values
