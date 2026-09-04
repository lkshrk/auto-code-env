import json
import sys


def load(path):
    f = open(path)
    data = json.load(f)
    return data


def main():
    cfg = load(sys.argv[1])
    if cfg["enabled"] == True:
        print("enabled")
    else:
        print("disabled")


main()
