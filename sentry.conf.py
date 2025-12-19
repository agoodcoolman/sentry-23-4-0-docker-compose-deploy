from sentry.conf.server import *  # NOQA

SENTRY_TSDB = env("SENTRY_TSDB", "sentry.tsdb.redis.RedisTSDB")

SENTRY_OPTIONS["redis.clusters"] = {
    "default": {
        "hosts": {
            0: {
                "host": env("SENTRY_REDIS_HOST", "redis"),
                "password": env("SENTRY_REDIS_PASSWORD", ""),
                "port": env("SENTRY_REDIS_PORT", "6379"),
                "db": env("SENTRY_REDIS_DB", "0"),
            }
        }
    }
}
