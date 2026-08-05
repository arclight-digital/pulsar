# Assert LOGO_W in cli/pulsar equals the visible width of every logo_art line.
# Lives outside the .bats file because the measurement needs real character
# semantics, and a heredoc inside a heredoc inside a test is its own hazard.
import re, sys

src = open(sys.argv[1]).read()
declared = int(re.search(r'^LOGO_W=(\d+)', src, re.M).group(1))
body = src.split('logo_art() {', 1)[1].split('\n}', 1)[0]
widths = {len(re.sub(r'\$\{[A-Za-z_]+\}', '', ln))
          for ln in re.findall(r'^"(.*)"\s*\\?$', body, re.M)}
print(f"declared LOGO_W={declared}, art widths={sorted(widths)}")
sys.exit(0 if widths == {declared} else 1)
