/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

// The C++ test (/usr/bin/cxxtest): iostreams, the standard containers,
// exceptions, std::thread with mutexes and atomics, chrono. ctest runs
// it; exits with 0 when everything held.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string &what) {
	if (!condition) {
		failures++;
		std::cout << "cxxtest: FAILED " << what << std::endl;
	}
}

struct Counted {
	static int alive;
	Counted() { alive++; }
	~Counted() { alive--; }
};
int Counted::alive = 0;

int deep_throw(int depth) {
	Counted guard;
	if (depth == 0)
		throw std::runtime_error("from the bottom");
	return deep_throw(depth - 1) + 1;
}

void test_streams_and_containers() {
	std::ostringstream text;
	text << "pi is about " << 3.14 << " and " << 42;
	check(text.str() == "pi is about 3.14 and 42", "ostringstream: " + text.str());
	std::vector<int> numbers{5, 1, 4, 2, 3};
	std::sort(numbers.begin(), numbers.end());
	check(numbers == std::vector<int>({1, 2, 3, 4, 5}), "sort");
	std::map<std::string, int> counts;
	for (auto word : {"a", "b", "a", "c", "a"})
		counts[word]++;
	check(counts["a"] == 3 && counts.size() == 3, "map");
	auto shared = std::make_shared<std::string>("shared");
	check(shared.use_count() == 1 && *shared == "shared", "shared_ptr");
}

void test_exceptions() {
	try {
		deep_throw(10);
		check(false, "no exception");
	} catch (const std::runtime_error &error) {
		check(std::string(error.what()) == "from the bottom", "exception message");
	}
	check(Counted::alive == 0, "destructors ran while unwinding");
	try {
		std::vector<int> small(2);
		(void)small.at(5);
		check(false, "at() did not throw");
	} catch (const std::out_of_range &) {
	}
}

void test_threads() {
	std::atomic<long> total{0};
	std::mutex lock;
	long guarded = 0;
	std::vector<std::thread> threads;
	for (int t = 0; t < 4; t++) {
		threads.emplace_back([&] {
			for (int i = 0; i < 10000; i++) {
				total++;
				std::lock_guard<std::mutex> hold(lock);
				guarded++;
			}
		});
	}
	for (auto &thread : threads)
		thread.join();
	check(total == 40000 && guarded == 40000, "threads");

	std::exception_ptr carried;
	std::thread thrower([&] {
		try {
			throw std::logic_error("in a thread");
		} catch (...) {
			carried = std::current_exception();
		}
	});
	thrower.join();
	try {
		if (carried)
			std::rethrow_exception(carried);
		check(false, "nothing carried");
	} catch (const std::logic_error &error) {
		check(std::string(error.what()) == "in a thread", "exception across threads");
	}
	auto start = std::chrono::steady_clock::now();
	std::this_thread::sleep_for(std::chrono::milliseconds(10));
	check(std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(5), "sleep_for");
}

} // namespace

int main() {
	test_streams_and_containers();
	test_exceptions();
	test_threads();
	if (failures == 0)
		std::cout << "cxxtest: passed" << std::endl;
	return failures == 0 ? 0 : 1;
}
