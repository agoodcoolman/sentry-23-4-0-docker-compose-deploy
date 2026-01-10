import os

from sentry.conf.server import *  # NOQA

env = os.environ.get

SENTRY_SINGLE_ORGANIZATION = True

SENTRY_OPTIONS["system.event-retention-days"] = int(env("SENTRY_EVENT_RETENTION_DAYS", "90"))

redis_password = env("REDIS_PASSWORD", "")

SENTRY_OPTIONS["redis.clusters"] = {
    "default": {
        "hosts": {0: {"host": "redis", "password": redis_password, "port": "6379", "db": "0"}}
    }
}

BROKER_URL = "redis://:{password}@{host}:{port}/{db}".format(
    **SENTRY_OPTIONS["redis.clusters"]["default"]["hosts"][0]
)

CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.memcached.MemcachedCache",
        "LOCATION": ["memcached:11211"],
        "TIMEOUT": 3600,
    }
}

SENTRY_CACHE = "sentry.cache.redis.RedisCache"

DEFAULT_KAFKA_OPTIONS = {
    "bootstrap.servers": "kafka:9092",
    "message.max.bytes": 50000000,
    "socket.timeout.ms": 1000,
}

SENTRY_EVENTSTREAM = "sentry.eventstream.kafka.KafkaEventStream"
SENTRY_EVENTSTREAM_OPTIONS = {"producer_configuration": DEFAULT_KAFKA_OPTIONS}
KAFKA_CLUSTERS["default"] = DEFAULT_KAFKA_OPTIONS

SENTRY_RATELIMITER = "sentry.ratelimits.redis.RedisRateLimiter"
SENTRY_BUFFER = "sentry.buffer.redis.RedisBuffer"
SENTRY_QUOTAS = "sentry.quotas.redis.RedisQuota"

SENTRY_TSDB = "sentry.tsdb.redissnuba.RedisSnubaTSDB"

SENTRY_SEARCH = "sentry.search.snuba.EventsDatasetSnubaSearchBackend"
SENTRY_SEARCH_OPTIONS = {}
SENTRY_TAGSTORE_OPTIONS = {}

SENTRY_DIGESTS = "sentry.digests.backends.redis.RedisBackend"

SENTRY_RELEASE_HEALTH = "sentry.release_health.metrics.MetricsReleaseHealthBackend"
SENTRY_RELEASE_MONITOR = "sentry.release_health.release_monitor.metrics.MetricReleaseMonitorBackend"

SENTRY_WEB_HOST = "0.0.0.0"
SENTRY_WEB_PORT = 9006

SENTRY_OPTIONS["mail.list-namespace"] = env("SENTRY_MAIL_HOST", "localhost")
SENTRY_OPTIONS["mail.from"] = f"sentry@{SENTRY_OPTIONS['mail.list-namespace']}"

SENTRY_FEATURES["projects:sample-events"] = False
SENTRY_FEATURES.update(
    {
        feature: True
        for feature in (
            "organizations:discover",
            "organizations:events",
            "organizations:global-views",
            "organizations:incidents",
            "organizations:integrations-issue-basic",
            "organizations:integrations-issue-sync",
            "organizations:invite-members",
            "organizations:metric-alert-builder-aggregate",
            "organizations:sso-basic",
            "organizations:sso-rippling",
            "organizations:sso-saml2",
            "organizations:performance-view",
            "organizations:advanced-search",
            "organizations:session-replay",
            "organizations:issue-platform",
            "organizations:profiling",
            "organizations:dashboards-mep",
            "organizations:mep-rollout-flag",
            "organizations:dashboards-rh-widget",
            "organizations:metrics-extraction",
            "organizations:transaction-metrics-extraction",
            "projects:custom-inbound-filters",
            "projects:data-forwarding",
            "projects:discard-groups",
            "projects:plugins",
            "projects:rate-limits",
            "projects:servicehooks",
        )
    }
)

GEOIP_PATH_MMDB = "/geoip/GeoLite2-City.mmdb"

CSP_REPORT_ONLY = True
