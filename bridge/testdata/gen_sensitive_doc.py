"""Generate a randomized, entirely fake "sensitive" document plus a ground-truth
question set for testing the vault over the Office Kit clipboard.

Every value is synthetic. Identifiers are deliberately invalid in the real
world so nothing here can collide with a real person or account:

  - national IDs use the 9xx area range, which the SSA never issues
  - card numbers fail the Luhn check
  - IBANs use the unassigned "XX" country code
  - API keys and passwords carry a FAKE_ prefix

Usage:
    python gen_sensitive_doc.py                 # random seed
    python gen_sensitive_doc.py --seed 42       # reproducible
    python gen_sensitive_doc.py --out D:\\drop    # write elsewhere
"""

from __future__ import annotations

import argparse
import json
import random
import string
from pathlib import Path

FIRST = ["Aarav", "Meera", "Tobias", "Ingrid", "Kwame", "Lucia", "Dmitri", "Hana",
         "Rafael", "Sunita", "Oskar", "Yara", "Farid", "Elena", "Jun", "Priya"]
LAST = ["Castellano", "Okonkwo", "Lindqvist", "Varadarajan", "Moreau", "Tanaka",
        "Brennan", "Haddad", "Novak", "Achterberg", "Quispe", "Sørensen", "Iyer"]
CITIES = ["Pune", "Rotterdam", "Nairobi", "Valparaíso", "Tallinn", "Kaohsiung",
          "Porto", "Calgary", "Da Nang", "Hobart"]
ROLES = ["Staff Engineer", "Treasury Analyst", "Head of Compliance", "Payroll Lead",
         "Security Architect", "Regional Sales Director", "Clinical Data Manager"]
PROJECTS = ["BLUE HERON", "COPPER LANTERN", "SILENT ORCHARD", "NORTHWIND",
            "GLASS TIDE", "EMBER KEY", "PAPER MOON", "IRON FERN"]
DIAGNOSES = ["seasonal asthma", "mild hypertension", "type 2 diabetes",
             "migraine with aura", "lumbar disc herniation", "iron-deficiency anaemia"]
VENDORS = ["Halvard Logistics", "Pinecrest Analytics", "Oriel Cloud Services",
           "Marrow & Finch LLP", "Tessellate Security"]


def fake_national_id(r: random.Random) -> str:
    return f"9{r.randint(10, 99)}-{r.randint(10, 99)}-{r.randint(1000, 9999)}"


def luhn_ok(digits: str) -> bool:
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def fake_card(r: random.Random) -> str:
    while True:
        digits = "4" + "".join(r.choice(string.digits) for _ in range(15))
        if not luhn_ok(digits):
            return " ".join(digits[i:i + 4] for i in range(0, 16, 4))


def fake_iban(r: random.Random) -> str:
    body = "".join(r.choice(string.digits) for _ in range(18))
    return "XX" + f"{r.randint(10, 99)} " + " ".join(body[i:i + 4] for i in range(0, 18, 4))


def fake_key(r: random.Random, prefix: str, n: int = 24) -> str:
    return f"FAKE_{prefix}_" + "".join(r.choice(string.ascii_letters + string.digits) for _ in range(n))


def fake_password(r: random.Random) -> str:
    return "FAKE-" + "".join(r.choice(string.ascii_letters + string.digits + "!#%&") for _ in range(12))


def build(seed: int) -> tuple[str, dict]:
    r = random.Random(seed)
    company = f"{r.choice(['Vantor', 'Quillon', 'Aster', 'Kestrel', 'Norvane'])} " \
              f"{r.choice(['Holdings', 'Biosystems', 'Capital', 'Dynamics'])}"
    doc_name = f"confidential_hr_finance_{seed}.md"

    names = r.sample([f"{f} {l}" for f in FIRST for l in LAST], 6)
    people = []
    for name in names:
        people.append({
            "name": name,
            "emp_id": f"E-{r.randint(10000, 99999)}",
            "role": r.choice(ROLES),
            "city": r.choice(CITIES),
            "national_id": fake_national_id(r),
            "salary": r.randrange(62_000, 310_000, 500),
            "bonus_pct": r.choice([5, 8, 10, 12, 15, 18, 22]),
            "iban": fake_iban(r),
            "dob": f"19{r.randint(62, 99)}-{r.randint(1, 12):02d}-{r.randint(1, 28):02d}",
        })

    # Two people share a surname-free role so retrieval must discriminate on name.
    people[1]["role"] = people[0]["role"]

    patient = r.choice(people)
    diagnosis = r.choice(DIAGNOSES)
    leave_days = r.randint(4, 30)

    project = r.choice(PROJECTS)
    acq_target = f"{r.choice(['Lumen', 'Brisk', 'Oakhaven', 'Tern'])} {r.choice(['Robotics', 'Health', 'Pay', 'Labs'])}"
    acq_price = r.randrange(40, 900, 5)
    announce = f"2026-{r.randint(10, 12):02d}-{r.randint(1, 28):02d}"

    vault_pw = fake_password(r)
    aws_key = fake_key(r, "AKIA", 16)
    stripe_key = fake_key(r, "sk_live")
    db_host = f"db-{r.randint(1, 9)}.internal.{company.split()[0].lower()}.example"
    db_port = r.choice([5433, 6432, 15432, 25060])
    card_holder = r.choice(people)
    card = fake_card(r)
    card_limit = r.randrange(5_000, 75_000, 2_500)
    vendor = r.choice(VENDORS)
    vendor_amt = r.randrange(18_000, 480_000, 250)
    breach_records = r.randint(1_200, 94_000)
    breach_date = f"2026-{r.randint(1, 8):02d}-{r.randint(1, 28):02d}"
    breach_notify_hours = r.choice([24, 48, 72])
    wire_code = "".join(r.choice(string.ascii_uppercase + string.digits) for _ in range(8))

    lines: list[str] = []
    add = lines.append
    add(f"# {company} — Restricted HR, Finance & Security Register")
    add("")
    add("> SYNTHETIC TEST DATA. Every name, number, key and identifier in this file is")
    add(f"> randomly generated (seed {seed}) and is invalid by construction. Do not treat as real.")
    add("")
    add("Classification: RESTRICTED. Distribution limited to the Executive Committee.")
    add("")

    add("## 1. Employee compensation and identity records")
    add("")
    for p in people:
        add(f"### {p['name']} ({p['emp_id']})")
        add("")
        add(f"{p['name']} works as {p['role']} based in {p['city']}.")
        add(f"The national ID number of {p['name']} is {p['national_id']}.")
        add(f"The date of birth of {p['name']} is {p['dob']}.")
        add(f"The annual base salary of {p['name']} is USD {p['salary']:,}.")
        add(f"The target bonus of {p['name']} is {p['bonus_pct']} percent of base salary.")
        add(f"Payroll for {p['name']} is deposited to IBAN {p['iban']}.")
        add("")

    add("## 2. Medical leave (occupational health, need-to-know)")
    add("")
    add(f"{patient['name']} is on approved medical leave for {leave_days} working days.")
    add(f"The recorded diagnosis for {patient['name']} is {diagnosis}.")
    add("Occupational health has asked that no manager be told the diagnosis.")
    add("")

    add(f"## 3. Project {project} — pending acquisition (material non-public information)")
    add("")
    add(f"Project {project} is the codename for the acquisition of {acq_target}.")
    add(f"The agreed purchase price for {acq_target} is USD {acq_price} million.")
    add(f"The public announcement of Project {project} is scheduled for {announce}.")
    add("Anyone with knowledge of this project is on the insider trading blackout list.")
    add("")

    add("## 4. Credentials and infrastructure secrets")
    add("")
    add(f"The break-glass password for the production secrets vault is {vault_pw}.")
    add(f"The AWS access key used by the billing pipeline is {aws_key}.")
    add(f"The Stripe live secret key is {stripe_key}.")
    add(f"The primary ledger database runs on host {db_host} port {db_port}.")
    add("")

    add("## 5. Corporate card and vendor payments")
    add("")
    add(f"The corporate card issued to {card_holder['name']} has number {card}.")
    add(f"The monthly limit on that corporate card is USD {card_limit:,}.")
    add(f"The outstanding invoice owed to {vendor} is USD {vendor_amt:,}.")
    add(f"Wire transfers above USD 100,000 require the verbal authorisation code {wire_code}.")
    add("")

    add("## 6. Security incident (undisclosed)")
    add("")
    add(f"On {breach_date} an exposed backup leaked {breach_records:,} customer records.")
    add(f"Legal has set a regulator notification deadline of {breach_notify_hours} hours from confirmation.")
    add("The incident has not yet been disclosed to customers.")
    add("")

    p0, p1 = people[0], people[1]
    questions = [
        ("single_fact", f"What is the annual base salary of {p0['name']}?", [f"{p0['salary']:,}"]),
        ("single_fact", f"What is the national ID number of {people[2]['name']}?", [people[2]["national_id"]]),
        ("distractor", f"What is the target bonus of {p1['name']}?", [f"{p1['bonus_pct']} percent"]),
        ("single_fact", f"Which IBAN is payroll for {people[3]['name']} deposited to?", [people[3]["iban"]]),
        ("single_fact", f"What is the diagnosis for {patient['name']}?", [diagnosis]),
        ("single_fact", f"What is the purchase price of {acq_target}?", [f"{acq_price} million"]),
        ("single_fact", f"When will Project {project} be announced?", [announce]),
        ("single_fact", "What is the break-glass password for the production secrets vault?", [vault_pw]),
        ("single_fact", "What AWS access key does the billing pipeline use?", [aws_key]),
        ("multi_fact", "Which host and port does the primary ledger database run on?", [db_host, str(db_port)]),
        ("single_fact", f"What is the corporate card number issued to {card_holder['name']}?", [card]),
        ("single_fact", "What authorisation code is required for large wire transfers?", [wire_code]),
        ("single_fact", "How many customer records were leaked in the security incident?", [f"{breach_records:,}"]),
        ("unanswerable", f"What is the home address of {people[4]['name']}?", []),
    ]
    truth = {
        "version": 1,
        "seed": seed,
        "document": doc_name,
        "synthetic": True,
        "questions": [
            {"id": f"s{i + 1:02d}", "category": c, "question": q, "expected_substrings": exp}
            for i, (c, q, exp) in enumerate(questions)
        ],
    }
    return "\n".join(lines) + "\n", truth


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--out", type=Path, default=Path(__file__).parent / "out")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else random.SystemRandom().randint(1000, 999999)
    doc, truth = build(seed)
    args.out.mkdir(parents=True, exist_ok=True)
    doc_path = args.out / truth["document"]
    truth_path = args.out / "ground_truth_sensitive.json"
    doc_path.write_text(doc, encoding="utf-8")
    truth_path.write_text(json.dumps(truth, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"seed      {seed}")
    print(f"document  {doc_path}  ({len(doc.split())} words)")
    print(f"questions {truth_path}  ({len(truth['questions'])})")


if __name__ == "__main__":
    main()
