#include "AstroIdentityMatcher.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <set>
#include <utility>

namespace panolume {
namespace {

constexpr double kPi = 3.14159265358979323846;

struct Neighbor {
    int index = -1;
    double dx = 0.0;
    double dy = 0.0;
    double distance = 0.0;
};

std::uint32_t triangle_hash(const Neighbor &first, const Neighbor &second) {
    const Neighbor *near = &first;
    const Neighbor *far = &second;
    if (near->distance > far->distance) {
        std::swap(near, far);
    }
    const double denominator = std::max(near->distance * far->distance, 1e-12);
    const double cosine = std::max(-1.0, std::min(
        1.0,
        (near->dx * far->dx + near->dy * far->dy) / denominator
    ));
    const double ratio = near->distance / std::max(far->distance, 1e-12);
    const double angle = std::acos(cosine) / kPi;
    const bool positiveChirality = near->dx * far->dy - near->dy * far->dx >= 0.0;
    const int ratioBin = std::max(0, std::min(20, static_cast<int>(std::llround(ratio * 20.0))));
    const int angleBin = std::max(0, std::min(24, static_cast<int>(std::llround(angle * 24.0))));
    return static_cast<std::uint32_t>(((ratioBin * 25) + angleBin) * 2 + (positiveChirality ? 1 : 0));
}

struct FlowEdge {
    int to = 0;
    int reverse = 0;
    int capacity = 0;
    double cost = 0.0;
    int source = -1;
    int target = -1;
};

IdentityDescriptor build_identity_descriptor(
    const std::vector<IdentityStar> &stars,
    int index,
    int neighborCount
) {
    IdentityDescriptor result;
    if (index < 0 || index >= static_cast<int>(stars.size())) {
        return result;
    }
    std::vector<Neighbor> neighbors;
    neighbors.reserve(stars.size() > 0 ? stars.size() - 1 : 0);
    for (int other = 0; other < static_cast<int>(stars.size()); ++other) {
        if (other == index) continue;
        const double dx = stars[static_cast<std::size_t>(other)].x - stars[static_cast<std::size_t>(index)].x;
        const double dy = stars[static_cast<std::size_t>(other)].y - stars[static_cast<std::size_t>(index)].y;
        const double distance = std::hypot(dx, dy);
        if (std::isfinite(distance) && distance > 1e-9) {
            neighbors.push_back({other, dx, dy, distance});
        }
    }
    std::sort(neighbors.begin(), neighbors.end(), [](const Neighbor &lhs, const Neighbor &rhs) {
        if (lhs.distance != rhs.distance) return lhs.distance < rhs.distance;
        return lhs.index < rhs.index;
    });
    if (neighbors.size() < 3) return result;
    if (neighbors.size() > static_cast<std::size_t>(neighborCount)) {
        neighbors.resize(static_cast<std::size_t>(neighborCount));
    }
    const double radialScale = std::max(neighbors.back().distance, 1e-9);
    for (int slot = 0; slot < 3; ++slot) {
        result.radial[static_cast<std::size_t>(slot)] =
            neighbors[static_cast<std::size_t>(slot)].distance / radialScale;
    }
    std::set<std::uint32_t> hashes;
    for (std::size_t first = 0; first < neighbors.size(); ++first) {
        for (std::size_t second = first + 1; second < neighbors.size(); ++second) {
            hashes.insert(triangle_hash(neighbors[first], neighbors[second]));
        }
    }
    result.orientedTriangleHashes.assign(hashes.begin(), hashes.end());
    return result;
}

void add_flow_edge(
    std::vector<std::vector<FlowEdge>> &graph,
    int from,
    int to,
    int capacity,
    double cost,
    int source = -1,
    int target = -1
) {
    FlowEdge forward{to, static_cast<int>(graph[to].size()), capacity, cost, source, target};
    FlowEdge reverse{from, static_cast<int>(graph[from].size()), 0, -cost, source, target};
    graph[from].push_back(forward);
    graph[to].push_back(reverse);
}

} // namespace

std::vector<IdentityDescriptor> build_identity_descriptors(
    const std::vector<IdentityStar> &stars,
    int neighborCount
) {
    neighborCount = std::max(3, neighborCount);
    std::vector<IdentityDescriptor> result(stars.size());
    for (int index = 0; index < static_cast<int>(stars.size()); ++index) {
        result[static_cast<std::size_t>(index)] = build_identity_descriptor(stars, index, neighborCount);
    }
    return result;
}

std::vector<IdentityDescriptor> build_identity_descriptors_for_indices(
    const std::vector<IdentityStar> &stars,
    const std::vector<int> &indices,
    int neighborCount
) {
    neighborCount = std::max(3, neighborCount);
    std::vector<IdentityDescriptor> result;
    result.reserve(indices.size());
    for (int index : indices) {
        result.push_back(build_identity_descriptor(stars, index, neighborCount));
    }
    return result;
}

IdentityDescriptorScore score_identity_descriptors(
    const IdentityDescriptor &source,
    const IdentityDescriptor &target
) {
    IdentityDescriptorScore score;
    // Count intersections without allocating. The descriptors are sorted and
    // unique, so this stays deterministic across platforms.
    std::size_t sourceIndex = 0;
    std::size_t targetIndex = 0;
    while (sourceIndex < source.orientedTriangleHashes.size()
        && targetIndex < target.orientedTriangleHashes.size()) {
        const std::uint32_t lhs = source.orientedTriangleHashes[sourceIndex];
        const std::uint32_t rhs = target.orientedTriangleHashes[targetIndex];
        if (lhs == rhs) {
            score.triangleVotes += 1;
            sourceIndex += 1;
            targetIndex += 1;
        } else if (lhs < rhs) {
            sourceIndex += 1;
        } else {
            targetIndex += 1;
        }
    }
    const double denominator = std::max<std::size_t>(
        1,
        std::min(source.orientedTriangleHashes.size(), target.orientedTriangleHashes.size())
    );
    double radialDelta = 0.0;
    for (std::size_t slot = 0; slot < source.radial.size(); ++slot) {
        radialDelta += std::abs(source.radial[slot] - target.radial[slot]);
    }
    const double hashSimilarity = static_cast<double>(score.triangleVotes) / denominator;
    const double radialSimilarity = 1.0 - std::min(1.0, radialDelta / 1.2);
    score.similarity = std::max(0.0, std::min(1.0, 0.8 * hashSimilarity + 0.2 * radialSimilarity));
    score.distance = 1.0 - score.similarity;
    return score;
}

std::vector<IdentityAssignment> minimum_cost_identity_assignment(
    int sourceCount,
    int targetCount,
    const std::vector<IdentityAssignmentCandidate> &candidates,
    double unmatchedCost
) {
    sourceCount = std::max(0, sourceCount);
    targetCount = std::max(0, targetCount);
    unmatchedCost = std::max(0.0, unmatchedCost);
    const int sourceNode = 0;
    const int firstSource = 1;
    const int firstTarget = firstSource + sourceCount;
    const int sinkNode = firstTarget + targetCount;
    std::vector<std::vector<FlowEdge>> graph(static_cast<std::size_t>(sinkNode + 1));
    for (int source = 0; source < sourceCount; ++source) {
        add_flow_edge(graph, sourceNode, firstSource + source, 1, 0.0);
        add_flow_edge(graph, firstSource + source, sinkNode, 1, unmatchedCost, source, -1);
    }
    for (int target = 0; target < targetCount; ++target) {
        add_flow_edge(graph, firstTarget + target, sinkNode, 1, 0.0);
    }
    std::vector<IdentityAssignmentCandidate> ordered = candidates;
    std::sort(ordered.begin(), ordered.end(), [](const auto &lhs, const auto &rhs) {
        if (lhs.source != rhs.source) return lhs.source < rhs.source;
        if (lhs.cost != rhs.cost) return lhs.cost < rhs.cost;
        return lhs.target < rhs.target;
    });
    for (const IdentityAssignmentCandidate &candidate : ordered) {
        if (candidate.source < 0 || candidate.source >= sourceCount
            || candidate.target < 0 || candidate.target >= targetCount
            || !std::isfinite(candidate.cost) || candidate.cost >= unmatchedCost) {
            continue;
        }
        add_flow_edge(
            graph,
            firstSource + candidate.source,
            firstTarget + candidate.target,
            1,
            std::max(0.0, candidate.cost),
            candidate.source,
            candidate.target
        );
    }

    const int nodeCount = sinkNode + 1;
    std::vector<double> potential(static_cast<std::size_t>(nodeCount), 0.0);
    for (int flow = 0; flow < sourceCount; ++flow) {
        const double infinity = std::numeric_limits<double>::infinity();
        std::vector<double> distance(static_cast<std::size_t>(nodeCount), infinity);
        std::vector<int> previousNode(static_cast<std::size_t>(nodeCount), -1);
        std::vector<int> previousEdge(static_cast<std::size_t>(nodeCount), -1);
        using QueueItem = std::pair<double, int>;
        std::priority_queue<QueueItem, std::vector<QueueItem>, std::greater<QueueItem>> queue;
        distance[sourceNode] = 0.0;
        queue.push({0.0, sourceNode});
        while (!queue.empty()) {
            const auto [currentDistance, node] = queue.top();
            queue.pop();
            if (currentDistance > distance[static_cast<std::size_t>(node)] + 1e-12) {
                continue;
            }
            for (int edgeIndex = 0; edgeIndex < static_cast<int>(graph[node].size()); ++edgeIndex) {
                const FlowEdge &edge = graph[node][static_cast<std::size_t>(edgeIndex)];
                if (edge.capacity <= 0) {
                    continue;
                }
                const double nextDistance = currentDistance + edge.cost
                    + potential[static_cast<std::size_t>(node)] - potential[static_cast<std::size_t>(edge.to)];
                if (nextDistance + 1e-12 < distance[static_cast<std::size_t>(edge.to)]) {
                    distance[static_cast<std::size_t>(edge.to)] = nextDistance;
                    previousNode[static_cast<std::size_t>(edge.to)] = node;
                    previousEdge[static_cast<std::size_t>(edge.to)] = edgeIndex;
                    queue.push({nextDistance, edge.to});
                }
            }
        }
        if (!std::isfinite(distance[static_cast<std::size_t>(sinkNode)])) {
            break;
        }
        for (int node = 0; node < nodeCount; ++node) {
            if (std::isfinite(distance[static_cast<std::size_t>(node)])) {
                potential[static_cast<std::size_t>(node)] += distance[static_cast<std::size_t>(node)];
            }
        }
        int node = sinkNode;
        while (node != sourceNode) {
            const int parent = previousNode[static_cast<std::size_t>(node)];
            const int edgeIndex = previousEdge[static_cast<std::size_t>(node)];
            if (parent < 0 || edgeIndex < 0) {
                break;
            }
            FlowEdge &edge = graph[parent][static_cast<std::size_t>(edgeIndex)];
            edge.capacity -= 1;
            graph[node][static_cast<std::size_t>(edge.reverse)].capacity += 1;
            node = parent;
        }
    }

    std::vector<IdentityAssignment> result;
    for (int source = 0; source < sourceCount; ++source) {
        const int node = firstSource + source;
        for (const FlowEdge &edge : graph[node]) {
            if (edge.target >= 0 && edge.capacity == 0) {
                result.push_back({source, edge.target, edge.cost});
                break;
            }
        }
    }
    std::sort(result.begin(), result.end(), [](const IdentityAssignment &lhs, const IdentityAssignment &rhs) {
        return lhs.source < rhs.source;
    });
    return result;
}

bool identity_matcher_characterization_self_test() {
    const std::vector<IdentityStar> source = {
        {10.0, 15.0, 1.0, 1.2}, {31.0, 8.0, 0.8, 1.1},
        {48.0, 27.0, 0.7, 1.3}, {19.0, 42.0, 0.6, 1.0},
        {62.0, 51.0, 0.5, 1.4}, {4.0, 66.0, 0.4, 1.2},
        {39.0, 76.0, 0.3, 1.1}, {78.0, 18.0, 0.2, 1.3}
    };
    std::vector<IdentityStar> target;
    target.reserve(source.size());
    const double radians = 0.41;
    const double cosine = std::cos(radians);
    const double sine = std::sin(radians);
    for (const IdentityStar &star : source) {
        target.push_back({
            80.0 + 1.7 * (cosine * star.x - sine * star.y),
            -35.0 + 1.7 * (sine * star.x + cosine * star.y),
            star.flux,
            star.sigma
        });
    }
    const auto sourceDescriptors = build_identity_descriptors(source, 6);
    const auto targetDescriptors = build_identity_descriptors(target, 6);
    if (sourceDescriptors.size() != targetDescriptors.size() || sourceDescriptors.size() < 4) {
        return false;
    }
    const IdentityDescriptorScore correct = score_identity_descriptors(
        sourceDescriptors[2], targetDescriptors[2]
    );
    const IdentityDescriptorScore impostor = score_identity_descriptors(
        sourceDescriptors[2], targetDescriptors[5]
    );
    if (correct.triangleVotes < 3 || correct.similarity <= impostor.similarity) {
        return false;
    }

    const std::vector<IdentityAssignmentCandidate> candidates = {
        {0, 0, 0.10}, {0, 1, 0.20}, {1, 0, 0.11}, {1, 1, 0.90}
    };
    const auto assignment = minimum_cost_identity_assignment(2, 2, candidates, 0.95);
    return assignment.size() == 2
        && assignment[0].source == 0 && assignment[0].target == 1
        && assignment[1].source == 1 && assignment[1].target == 0;
}

} // namespace panolume
