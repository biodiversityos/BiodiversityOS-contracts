#!/usr/bin/env python3
"""Read the behaviour a reporter actually described, from their own words.

The survey has no behaviour column; it has Spanish field notes. Where a note
states what the animal was doing, that is recorded observation and belongs in
the record. Where it does not, the behaviour stays unknown — it is not inferred
from species, site or anything else.

Categories come from the vocabulary the notes actually use, not from a list
written in advance: `swimming` and `sheltering` are the two most common things
these reporters describe, and neither existed in the original enum.
"""
import re
import unicodedata

# Most specific first: a note saying an animal rested in a cave and then swam
# off is better recorded as the notable behaviour than as generic locomotion.
PRIORITY = [
    "stranded",
    "mating",
    "feeding",
    "hunting",
    "sheltering",
    "resting",
    "swimming",
]

PATTERNS = {
    # Beached or trapped. Carrying a fishing line is entanglement, a different
    # thing, and is deliberately not folded in here.
    "stranded":  r"\bvarad|encall",
    "mating":    r"aparea|apareamiento|cortejo|copul|reproduc",
    # "carnada"/"cebo" describe a bait box the divers brought, not the animal
    # feeding, so they are not evidence of feeding.
    "feeding":   r"comiend|aliment(?!o\b)|devorand|masticand",
    "hunting":   r"cazand|\bcaza\b|cazar|persigui|acechand|atacand|\bataco\b|emboscad",
    # Only actual shelters. "en el arrecife" or "en el coral" is where the animal
    # was, not what it was doing, and matching those made swimming and resting
    # notes read as sheltering.
    "sheltering": r"escondid|refugi|guarida|\boculto|metid\w*\s+(en|bajo|debajo)"
                  r"|(en|bajo|debajo|dentro)\s+(de\s+)?(la\s+|el\s+|un\s+|una\s+)?"
                  r"(cueva|cuevita|bolon|bolones|grieta|tunel|zurco|orificio|guarida)",
    "resting":   r"descans|reposa|dormid|echad|acostad|posad|quiet\w|inmovil|sin moverse",
    "swimming":  r"\bnad(ando|aba|aban|o|an|aron|ar)\b|nadand|pasand|cruzand|transitand"
                 r"|dando vueltas|circuland|girand|rondand|de paso|se alejo|huyend",
}

# Explicit speculation. "parecia cazando" is an observer describing what they
# saw; "quiza reproduccion" is them guessing, and a guess must not be recorded
# as an observation.
SPECULATION = r"\b(quiza|quizas|tal vez|talvez|posiblemente|probablemente|no se si|creo que)\b"

# A note that denies a behaviour must not be read as asserting it.
NEGATION = r"\b(no|nunca|sin)\s+(se\s+)?\w{0,12}\s*$"


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in text if not unicodedata.combining(c))


def negated(text: str, start: int) -> bool:
    """True when the 30 characters before a match negate it."""
    return bool(re.search(NEGATION, text[max(0, start - 30):start]))


def classify(comment: str) -> tuple[str, str | None]:
    """Return (behaviour, matched phrase). Unknown when nothing is described."""
    if not comment:
        return "unknown", None
    text = normalize(comment)

    speculative = bool(re.search(SPECULATION, text))

    found = {}
    for name, pattern in PATTERNS.items():
        for m in re.finditer(pattern, text):
            if negated(text, m.start()):
                continue
            # A hedged note can still support plain locomotion, but not a claim
            # as strong as mating or hunting.
            if speculative and name not in ("swimming", "resting"):
                continue
            found[name] = m.group(0)
            break

    for name in PRIORITY:
        if name in found:
            return name, found[name]
    return "unknown", None
