#!/usr/bin/env python3
"""Generate interleaved synthetic computer logs and fake transactions."""

import logging
import os
import random
import time
from logging.handlers import RotatingFileHandler

LOG_FILE = os.environ.get("SYNTHETIC_LOG", "/var/log/synthetic.log")

LOGGER = logging.getLogger("synthetic")
LOGGER.setLevel(logging.DEBUG)

FILE_HANDLER = RotatingFileHandler(LOG_FILE, maxBytes=10 * 1024 * 1024, backupCount=3)
FILE_HANDLER.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
LOGGER.addHandler(FILE_HANDLER)

CONSOLE = logging.StreamHandler()
CONSOLE.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
LOGGER.addHandler(CONSOLE)

LEVELS = ["INFO", "INFO", "INFO", "WARNING", "ERROR"]
SOURCES = ["kernel", "app", "db", "network", "auth"]

LOG_MESSAGES = {
    "kernel": [
        "CPU0: temperature above threshold (%s C)",
        "Memory pressure: %s%% of RAM in use",
        "Disk I/O latency spike detected on sda",
        "Process %s killed by OOM killer",
        "NIC link down on eth0, restarting",
    ],
    "app": [
        "User %s session started from %s",
        "Cache miss for key '%s', fetching from origin",
        "Queue depth at %s, processing worker %s",
        "Endpoint /api/v1/status returned 200 in %sms",
        "Configuration reloaded, %s settings applied",
    ],
    "db": [
        "Query took %sms (> threshold), index scan on table %s",
        "Replica lag at %ss for database %s",
        "Connection pool usage at %s%%",
        "Deadlock detected, retrying transaction %s",
        "Backup snapshot %s created successfully",
    ],
    "network": [
        "Packet loss %s%% observed on route to %s",
        "TLS handshake with %s completed in %sms",
        "Bandwidth usage at %s Mbps on interface eth0",
        "Flow table updated, %s new flows installed",
        "Latency to %s is %sms",
    ],
    "auth": [
        "Login attempt for user %s from %s",
        "Failed password for user %s (attempt %s)",
        "Token refreshed for user %s",
        "MFA challenge issued to user %s",
        "Account %s locked after %s failed attempts",
    ],
}

MERCHANTS = [
    "Acme Coffee",
    "Globex Grocers",
    "Initech Software",
    "Stark Electronics",
    "Umbrella Pharmacy",
    "Vandelay Imports",
]
CURRENCIES = ["USD", "EUR", "GBP", "JPY"]
TX_STATUSES = ["approved", "approved", "approved", "approved", "declined", "refunded"]


def random_log_line():
    source = random.choice(SOURCES)
    level = random.choice(LEVELS)
    message = random.choice(LOG_MESSAGES[source])
    args = [random.choice(SOURCE_ARGS[source]) for _ in range(message.count("%s"))]
    body = message % tuple(args)
    return level, "%s %s" % (source, body)


SOURCE_ARGS = {
    "kernel": [
        str(random.randint(60, 105)),
        str(random.randint(75, 99)),
        str(random.randint(1000, 9999)),
        str(random.randint(1000, 9999)),
    ],
    "app": [
        str(random.randint(1000, 9999)),
        "%d.%d.%d.%d" % tuple(random.randint(0, 255) for _ in range(4)),
        str(random.randint(1000, 9999)),
        str(random.randint(1000, 9999)),
        str(random.randint(1, 100)),
    ],
    "db": [
        str(random.randint(200, 5000)),
        random.choice(["users", "orders", "events"]),
        str(random.randint(1, 30)),
        str(random.randint(1000, 9999)),
        str(random.randint(10000, 99999)),
    ],
    "network": [
        str(random.randint(0, 5)),
        "%d.%d.%d.%d" % tuple(random.randint(0, 255) for _ in range(4)),
        str(random.randint(1, 900)),
        str(random.randint(1000, 9999)),
        str(random.randint(5, 500)),
    ],
    "auth": [
        str(random.randint(1000, 9999)),
        "%d.%d.%d.%d" % tuple(random.randint(0, 255) for _ in range(4)),
        str(random.randint(1000, 9999)),
        str(random.randint(1, 5)),
        str(random.randint(1, 5)),
    ],
}


def random_transaction():
    tx_id = "TXN-%08d" % random.randint(0, 99999999)
    user_id = "USR-%05d" % random.randint(0, 99999)
    amount = round(random.uniform(1.0, 2500.0), 2)
    currency = random.choice(CURRENCIES)
    merchant = random.choice(MERCHANTS)
    status = random.choice(TX_STATUSES)
    return "transaction id=%s user=%s amount=%.2f%s merchant=%r status=%s" % (
        tx_id,
        user_id,
        amount,
        currency,
        merchant,
        status,
    )


def main():
    while True:
        if random.random() < 0.55:
            level, body = random_log_line()
            LOGGER.log(getattr(logging, level), body)
        else:
            LOGGER.info(random_transaction())
        time.sleep(random.uniform(0.5, 2.0))


if __name__ == "__main__":
    main()
