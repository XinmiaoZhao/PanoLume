#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace panolume {

struct IdentityStar {
    double x = 0.0;
    double y = 0.0;
    double flux = 0.0;
    double sigma = 1.0;
};

struct IdentityDescriptor {
    std::array<double, 3> radial = {1.0, 1.0, 1.0};
    std::vector<std::uint32_t> orientedTriangleHashes;
};

struct IdentityDescriptorScore {
    int triangleVotes = 0;
    double similarity = 0.0;
    double distance = 1.0;
};

struct IdentityAssignmentCandidate {
    int source = -1;
    int target = -1;
    double cost = 1.0;
};

struct IdentityAssignment {
    int source = -1;
    int target = -1;
    double cost = 1.0;
};

std::vector<IdentityDescriptor> build_identity_descriptors(
    const std::vector<IdentityStar> &stars,
    int neighborCount = 6
);

std::vector<IdentityDescriptor> build_identity_descriptors_for_indices(
    const std::vector<IdentityStar> &stars,
    const std::vector<int> &indices,
    int neighborCount = 6
);

IdentityDescriptorScore score_identity_descriptors(
    const IdentityDescriptor &source,
    const IdentityDescriptor &target
);

std::vector<IdentityAssignment> minimum_cost_identity_assignment(
    int sourceCount,
    int targetCount,
    const std::vector<IdentityAssignmentCandidate> &candidates,
    double unmatchedCost = 1.0
);

bool identity_matcher_characterization_self_test();

} // namespace panolume
