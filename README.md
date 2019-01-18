# Dynflow Benchmark

A tool for measuring Dynflow performance. It should be possible to use it in
various environments, both in development environment as well as in production.

## Usage

### In development setup

We recommend testing against Postgres database, as that's the database we're
tuning the Dynlfow the most
against.

```bash
# In dynflow directory

# update to match your db credentials
DB=dynflow_benchmark; dropdb -U postgres "$DB"; createdb -U postgres "$DB"


../dynflow-benchmark/benchmark.rb
```

See `benchmark.rb -v` for more options

### In production setup

In production, we're testing Dynflow in the Foreman/Katello setup. Follow
[Forklift](instructions) on how to get the setup up and running.

```bash
# Prepare database
DB=dynflow_benchmark
/bin/sudo -u postgres dropdb "$DB"
/bin/sudo -u postgres createdb "$DB"

# Clone the repo to foreman readable directory
git clone git@github.com:Dynflow/dynflow-benchmark.git /var/lib/foreman/dynflow-benchmark
cd /var/lib/foreman/dynflow-benchmark

# Enable scl and run the tool
scl enable tfm bash
./benchmark.rb
```
