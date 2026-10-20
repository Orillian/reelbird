// Runs before every test file (bunfig.toml): a separate database and a known webhook secret.
process.env.DATABASE_URL = "postgres://postgres@127.0.0.1:54329/reelbird_cloud_test";
process.env.DEV = "1";
process.env.STRIPE_WEBHOOK_SECRET = "whsec_test_reelbird";
process.env.STRIPE_PORTAL_LINK = "https://billing.stripe.com/p/login/test_portal";
