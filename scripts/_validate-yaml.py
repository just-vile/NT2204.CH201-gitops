import sys, glob, yaml, os

ok = []
fail = []
for f in sorted(glob.glob("/work/**/*.yaml", recursive=True)):
    if "/charts/saga-service/templates/" in f:
        continue
    try:
        with open(f, "r", encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))
        ok.append(f)
    except Exception as e:
        fail.append((f, str(e)))

print(f"OK   : {len(ok)} files")
print(f"FAIL : {len(fail)} files")
for f, e in fail:
    print("---")
    print(f"FAIL {f}")
    print(e)

sys.exit(0 if not fail else 1)
