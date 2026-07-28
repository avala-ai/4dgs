# Target names are the same in every language directory of this repository.
.PHONY: sync build test lint examples docs clean

sync:
	python3 -m pip install -e ./fourdgs[dev]

build:
	python3 -m build fourdgs

test:
	python3 -m pytest fourdgs/tests -q

lint:
	python3 -m ruff check fourdgs conformance examples
	python3 -m ruff format --check fourdgs conformance examples

examples:
	python3 examples/encode_synthetic.py
	python3 examples/decode_summary.py

docs:
	python3 -m sphinx -W docs docs/__build__

clean:
	rm -rf fourdgs/dist fourdgs/build docs/__build__ .pytest_cache .ruff_cache
