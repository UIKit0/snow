/**************************************************************************
**
**   SNOW - CS224 BROWN UNIVERSITY
**
**   wil.cu
**   Author: mliberma
**   Created: 8 Apr 2014
**
**************************************************************************/

#ifndef WIL_CU
#define WIL_CU

#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cuda_runtime.h> // prevents syntax errors on __global__ and __device__, among other things

#if defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 200)
  # error printf is only supported on devices of compute capability 2.0 and higher, please compile with -arch=sm_20 or higher
#endif

extern "C"  {
    void testColliding();
    void testColliderNormal();
    void testGridMath();

}

// Collider
#include <glm/geometric.hpp>
#include "math.h"   // this imports the CUDA math library
#include "sim/collider.h"

// isColliding functions
typedef bool (*isCollidingFunc) (const ImplicitCollider &collider, const glm::vec3 &position);

/**
 * A collision occurs when the point is on the OTHER side of the normal
 */
__device__ bool isCollidingHalfPlane(const glm::vec3 &planePoint, const glm::vec3 &planeNormal, const glm::vec3 &position){
    glm::vec3 vecToPoint = position - planePoint;
    return (glm::dot(vecToPoint, planeNormal) <= 0);
}

/**
 * Defines a halfplane such that collider.center is a point on the plane,
 * and collider.param is the normal to the plane.
 */
__device__ bool isCollidingHalfPlaneImplicit(const ImplicitCollider &collider, const glm::vec3 &position){
    return isCollidingHalfPlane(collider.center, collider.param, position);
}

/**
 * Defines a sphere such that collider.center is the center of the sphere,
 * and collider.param.x is the radius.
 */
__device__ bool isCollidingSphereImplicit(const ImplicitCollider &collider, const glm::vec3 &position){
    float radius = collider.param.x;
    return (glm::length(position-collider.center) <= radius);
}


/** array of colliding functions. isCollidingFunctions[collider.type] will be the correct function */
__device__ isCollidingFunc isCollidingFunctions[2] = {isCollidingHalfPlaneImplicit, isCollidingSphereImplicit};


/**
 * General purpose function for handling colliders
 */
__device__ bool isColliding(const ImplicitCollider &collider, const glm::vec3 &position){
    return isCollidingFunctions[collider.type](collider, position);
}


// colliderNormal functions

/**
 * Returns the (normalized) normal of the collider at the position.
 * Note: this function does NOT check that there is a collision at this point, and behavior is undefined if there is not.
 */
typedef void (*colliderNormalFunc) (const ImplicitCollider &collider, const glm::vec3 &position, glm::vec3 &normal);

__device__ void colliderNormalSphere(const ImplicitCollider &collider, const glm::vec3 &position, glm::vec3 &normal){
    normal = glm::normalize(position - collider.center);
}

__device__ void colliderNormalHalfPlane(const ImplicitCollider &collider, const glm::vec3 &position, glm::vec3 &normal){
    normal = collider.param; //The halfplanes normal is stored in collider.param
}

/** array of colliderNormal functions. colliderNormalFunctions[collider.type] will be the correct function */
__device__ colliderNormalFunc colliderNormalFunctions[2] = {colliderNormalHalfPlane, colliderNormalSphere};

__device__ void colliderNormal(const ImplicitCollider &collider, const glm::vec3 &position, glm::vec3 &normal){
    colliderNormalFunctions[collider.type](collider, position, normal);
}

__device__ void checkForAndHandleCollisions(ImplicitCollider *colliders, int numColliders, float coeffFriction, const glm::vec3 &position, glm::vec3 &velocity ){
    for (int i = 0; i < numColliders; i++){
        ImplicitCollider &collider = colliders[i];
        if (isColliding(collider, position)){
            glm::vec3 vRel = velocity - collider.velocity;
            glm::vec3 normal;
            colliderNormal(collider, position, normal);
            float vn = glm::dot(vRel, normal);
            if (vn < 0 ){ //Bodies are not separating and a collision must be applied
                glm::vec3 vt = vRel - normal*vn;
                float magVt = glm::length(vt);
                if (magVt <= -coeffFriction*vn){ // tangential velocity not enough to overcome force of friction
                    vRel = glm::vec3(0);
                } else{
                    vRel = (1+coeffFriction*vn/magVt)*vt;
                }
            }
            velocity = vRel + collider.velocity;
        }
    }
}

// Grid math

#include "tim.cu" // should really be snow.cu or grid.cu depending on how we break it up
#include "decomposition.cu"
#include "weighting.cu"
#include "sim/particlegrid.h"
#include "sim/world.h"


__host__ __device__ void computeSigma(Particle &particle, WorldParams *worldParams, glm::mat3 &sigma){
    glm::mat3 &Fp = particle.plasticF; //for the sake of making the code look like the math
    glm::mat3 &Fe = particle.elasticF;

    float Jp = glm::determinant(Fp);
    float Je = glm::determinant(Fe);

    glm::mat3 Re, Se;
    computePD(Fe, Re, Se);

    float muFp = worldParams->mu*exp(worldParams->xi*(1-Jp));
    float lambdaFp = worldParams->lambda*exp(worldParams->xi*(1-Jp));

    sigma = (2*muFp/Jp)*(Fe-Re)*glm::transpose(Fe)+(lambdaFp/Jp)*(Je-1)*Je*glm::mat3(1.0f);
}


__device__ void atomicAdd(glm::vec3 *add, glm::vec3 toAdd){
    atomicAdd(&(add->x), toAdd.x);
    atomicAdd(&(add->y), toAdd.y);
    atomicAdd(&(add->z), toAdd.z);
}

/**
 * Called on each particle.
 *
 * Each particle adds it's mass, velocity and force contribution to the grid nodes within 2h of itself.
 *
 * In:
 * particleData -- list of particles
 * grid -- Stores grid paramters
 * worldParams -- Global parameters dealing with the physics of the world
 *
 * Out:
 * nodes -- list of every node in grid ((dim.x+1)*(dim.y+1)*(dim.z+1))
 *
 */
__global__ void computeCellMassVelocityAndForce(Particle *particleData, Grid *grid, WorldParams *worldParams, ParticleGrid::Node *nodes){
    int particleIdx = blockIdx.x*blockDim.x + threadIdx.x;
    Particle &particle = particleData[particleIdx];

    glm::ivec3 gridIJK;
    positionToGridIJK(particle.position, grid, gridIJK); // NOTE: since we are working with nodes, we may need to reconcile grid.dim and size of nodes at some point

    glm::mat3 sigma;
    computeSigma(particle, worldParams, sigma);

    // Apply particles contribution of mass, velocity and force to surrounding nodes
    glm::ivec3 min = glm::max(glm::ivec3(0.0f), gridIJK-2);
    glm::ivec3 max = glm::min(grid->dim, gridIJK+2); //+1 because we are working on nodes
    for (int i = min.x; i <= max.x; i++){
        for (int j = min.y; j <= max.y; j++){
            for (int k = min.z; k <= max.z; k++){
                glm::vec3 nodePosition = glm::vec3(i, j, k)*grid->h + grid->pos;
                int currIdx = getGridIndex(i, j, k, grid);
                ParticleGrid::Node &node = nodes[currIdx];

                float w;
                glm::vec3 wg;
                weightAndGradient((particle.position-nodePosition)/grid->h, w, wg);

                atomicAdd(&node.mass, particle.mass*w);
                atomicAdd(&node.velocity, particle.velocity*particle.mass*w);
                atomicAdd(&node.force, particle.volume*sigma*wg);
            }
        }
    }
}

/**
 * Called on each grid node.
 *
 * Updates the velocities of each grid node based on forces and collisions
 *
 * In:
 * nodes -- list of all nodes in the grid.
 * dt -- delta time, time step of simulation
 * colliders -- array of colliders in the scene.
 * numColliders -- number of colliders in the scene
 * worldParams -- Global parameters dealing with the physics of the world
 * grid -- parameters defining the grid
 *
 * Out:
 * nodes -- updated velocity and velocityChange
 *
 */
__global__ void updateVelocities(ParticleGrid::Node *nodes, float dt, ImplicitCollider* colliders, int numColliders, WorldParams *worldParams, Grid *grid){
    int nodeIdx = blockIdx.x*blockDim.x + threadIdx.x;
    int gridI, gridJ, gridK;
    gridIndexToIJK(nodeIdx, gridI, gridJ, gridK, grid);
    ParticleGrid::Node &node = nodes[nodeIdx];
    glm::vec3 nodePosition = glm::vec3(gridI, gridJ, gridK)*grid->h + grid->pos;

    glm::vec3 tmpVelocity = node.velocity + dt*(node.force/node.mass);
    checkForAndHandleCollisions(colliders, numColliders, worldParams->coeffFriction, nodePosition, tmpVelocity);
    node.velocityChange = tmpVelocity - node.velocity;
    node.velocity = tmpVelocity;
}

/**
 * Updates the grid's nodes for this time step. First computes the mass, velocity and force acting on the grid
 * using a kernel over the particles and then updates the velocity in a second kernel over the grid nodes.
 * @param particleData
 * @param grid
 * @param worldParams
 * @param nodes
 * @param dt
 * @param colliders
 * @param numColliders
 */
void gridMath(Particle *particleData, int numParticles, Grid *grid, WorldParams *worldParams, ParticleGrid::Node *nodes,
              float dt, ImplicitCollider* colliders, int numColliders){
    computeCellMassVelocityAndForce<<< numParticles / 512, 512 >>>(particleData, grid, worldParams, nodes);
    updateVelocities<<< grid->nodeCount() / 512, 512 >>>(nodes, dt, colliders, numColliders, worldParams, grid);
}


// Begin testing code:

__global__ void testHalfPlaneColliding(){
    printf("\nTesting half plane colliding:\n");
    ImplicitCollider halfPlane;
    halfPlane.center = glm::vec3(0,0,0);
    halfPlane.param = glm::vec3(0,1,0);
    halfPlane.type = HALF_PLANE;

    if (isColliding(halfPlane, glm::vec3(1,1,1))){ //expect no collision
        printf("\t[FAILED]: Simple non-colliding test on halfplane \n");
    } else{
        printf("\t[PASSED]: Simple non-colliding test on half plane \n");
    }
    if (!isColliding(halfPlane, glm::vec3(-1,-1,-1))){ // expect collision
        printf("\t[FAILED]: Simple colliding test on halfplane failed\n");
    } else{
        printf("\t[PASSED]: Simple colliding test on half plane \n");
    }

    halfPlane.center = glm::vec3(0,10,0);
    halfPlane.param = glm::vec3(1,1,0);
    halfPlane.type = HALF_PLANE;

    if (isColliding(halfPlane, glm::vec3(2,11,1))){ //expect no collision
        printf("\t[FAILED]: Non-colliding test on halfplane \n");
    } else{
        printf("\t[PASSED]: Non-colliding test on half plane \n");
    }
    if (!isColliding(halfPlane, glm::vec3(-1,-1,-1))){ // expect collision
        printf("\t[FAILED]: Colliding test on halfplane \n");
    } else{
        printf("\t[PASSED]: Colliding test on half plane \n");
    }

    printf("Done testing half plane colliding\n\n");
}

__global__ void testSphereColliding(){
    printf("\nTesting sphere colliding:\n");
    ImplicitCollider sphereCollider;
    sphereCollider.center = glm::vec3(0,0,0);
    sphereCollider.param = glm::vec3(1,0,0);
    sphereCollider.type = SPHERE;

    if (isColliding(sphereCollider, glm::vec3(1,1,1))){ //expect no collision
        printf("\t[FAILED]: Simple non-colliding test\n");
    } else{
        printf("\t[PASSED]: Simple non-colliding test\n");
    }
    if (!isColliding(sphereCollider, glm::vec3(.5,0,0))){ // expect collision
        printf("\t[FAILED]: Simple colliding test\n");
    } else{
        printf("\t[PASSED]: Simple colliding test\n");
    }

    sphereCollider.center = glm::vec3(0,10,0);
    sphereCollider.param = glm::vec3(3.2,0,0);
    sphereCollider.type = SPHERE;

    if (isColliding(sphereCollider, glm::vec3(0,0,0))){ //expect no collision
        printf("\t[FAILED]: Non-colliding test \n");
    } else{
        printf("\t[PASSED]: Non-colliding test \n");
    }
    if (!isColliding(sphereCollider, glm::vec3(-1,10,-1))){ // expect collision
        printf("\t[FAILED]: Colliding test\n");
    } else{
        printf("\t[PASSED]: Colliding test\n");
    }


    printf("Done testing sphere colliding\n\n");
}

void testColliding(){
    testHalfPlaneColliding<<<1,1>>>();
    testSphereColliding<<<1,1>>>();
    cudaDeviceSynchronize();
}

__host__ __device__ bool operator==(const glm::vec3 &vecA, const glm::vec3 &vecB)
{
   const double epsilion = 0.0001;  // choose something apprpriate.

   return    std::fabs(vecA[0] -vecB[0]) < epsilion
          && std::fabs(vecA[1] -vecB[1]) < epsilion
          && std::fabs(vecA[2] -vecB[2]) < epsilion;
}

__global__ void testHalfPlaneColliderNormal(){
    printf("\nTesting half plane colliderNormal:\n");
    ImplicitCollider halfPlane;
    halfPlane.center = glm::vec3(0,0,0);
    halfPlane.param = glm::vec3(0,1,0);
    halfPlane.type = HALF_PLANE;


    glm::vec3 normal;
    glm::vec3 expected = glm::vec3(0,1,0);
    colliderNormal(halfPlane, glm::vec3(1,-.001, 1), normal);
    if (normal == expected){
        printf("\t[PASSED]: Simple colliderNormal test on half plane \n");
    } else{
        printf("\t[FAILED]: Simple colliderNormal test on halfplane \n");
    }

    halfPlane.center = glm::vec3(0,10,0);
    halfPlane.param = glm::vec3(1,1,0);
    halfPlane.type = HALF_PLANE;

    expected = glm::vec3(1,1,0);
    colliderNormal(halfPlane, glm::vec3(0,9.999, 0), normal);
    if (expected == normal){
        printf("\t[PASSED]: colliderNormal test on half plane \n");
    } else{
        printf("\t[FAILED]: colliderNormal test on halfplane \n");
    }

    printf("Done testing half plane colliderNormal\n\n");
}

__global__ void testSphereColliderNormal(){
    printf("\nTesting sphere colliderNormal:\n");
    ImplicitCollider sphereCollider;
    sphereCollider.center = glm::vec3(0,0,0);
    sphereCollider.param = glm::vec3(1,0,0);
    sphereCollider.type = SPHERE;

    glm::vec3 normal;
    glm::vec3 expected = glm::normalize(glm::vec3(1.0f));
    colliderNormal(sphereCollider, glm::vec3(.1f), normal);
    if (normal == expected){
        printf("\t[PASSED]: Simple colliderNormal test\n");
    } else{
        printf("\t[FAILED]: Simple colliderNormal test\n");
    }

    sphereCollider.center = glm::vec3(0,10,0);
    sphereCollider.param = glm::vec3(3.2,0,0);
    sphereCollider.type = SPHERE;

    expected = glm::vec3(0,1,0);
    colliderNormal(sphereCollider, glm::vec3(0,11,0), normal);
    if (normal == expected){
        printf("\t[PASSED]: colliderNormal test \n");
    } else{
       printf("\t[FAILED]: colliderNormal test \n");
    }

    printf("Done testing sphere colliderNormal\n\n");
}

void testColliderNormal(){
    testHalfPlaneColliderNormal<<<1,1>>>();
    testSphereColliderNormal<<<1,1>>>();
    cudaDeviceSynchronize();
}

__device__ float maxNorm(glm::mat3 m){
    float norm = -INFINITY;
    for (int row = 0; row < 3; row++){
        for (int col = 0; col < 3; col++){
            norm=glm::max(norm,m[col][row]); //note glm is column major
        }
    }
    return norm;
}

__global__ void testComputeSigma(){
    printf("\tTesting compute sigma \n");
    Particle p;
    p.mass = 1;
    p.elasticF = glm::mat3(1.0f);
    p.plasticF = glm::mat3(1.0f);

    WorldParams wp;
    wp.mu = 1;
    wp.lambda = 1;
    wp.xi = 1;

    glm::mat3 sigma;
    computeSigma(p, &wp, sigma);

    glm::mat3 expected = glm::mat3(0.0f);

    if (0 && maxNorm(expected-sigma) > 1e-4){
        printf("\t\t[FAILED]: Simple compute sigma\n");
    } else{
        printf("\t\t[PASSED]: Simple compute sigma\n");
    }

    // more complex test
    p.elasticF = glm::mat3(1.f, 2.f, 3.f,
                           4.f, 5.f, 6.f,
                           7.f, 8.f, 9.0f);
    p.plasticF = glm::mat3(1.0f);

    computeSigma(p, &wp, sigma);

    expected = glm::mat3(122.9580,  146.6232,  170.2883,
                         146.6232,  174.9487,  203.2743,
                         170.2883,  203.2743,  236.2603);

    if (0 && maxNorm(expected-sigma) > 1e-4){
        printf("\t\t[FAILED]: Complex compute sigma\n");
    } else{
        printf("\t\t[PASSED]: Complex compute sigma\n");
    }

    // even more complex test

    p.elasticF = glm::mat3(0.6062,  0.3500, 0,
                           -0.3500, 0.6062, 0,
                           0,       0,      0.7000);
    p.plasticF = glm::mat3( 0.9000,  0,  0,
                            0, 0.6364, 0.6364,
                            0,-0.6364, 0.6364);

    computeSigma(p, &wp, sigma);

    expected = glm::mat3(-1.1608, 0.0000, 0,
                         0, -1.1608, 0,
                         0,  0, -1.1608);

    if (0 && maxNorm(expected-sigma) > 1e-4){
        printf("\t\t[FAILED]: Complex compute sigma\n");
    } else{
        printf("\t\t[PASSED]: Complex compute sigma\n");
    }

    printf("\tDone testing compute sigma \n");
}



__global__ void testCheckForAndHandleCollisions(){
    printf("\tTesting checkAndHandleCollisions\n");
    glm::vec3 position = glm::vec3(0,0,0);
    glm::vec3 velocity = glm::vec3(0,-1,-1);

    ImplicitCollider floor;
    floor.center = glm::vec3(0,0,0);
    floor.param = glm::vec3(0,1,0);
    floor.type = HALF_PLANE;

    ImplicitCollider colliders[1] = {floor};

    float coeffFriction = .5;

    checkForAndHandleCollisions(colliders, 1, coeffFriction, position, velocity);
    glm::vec3 expected = glm::vec3(0,0,-.5);

    if (velocity == expected){
        printf("\t\t[PASSED]: Simple checkAndHandleCollisions test\n");
    } else{
        printf("\t\t[FAILED]: Simple checkAndHandleCollisions test\n");
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    velocity = glm::vec3(0,-1,-1);
    coeffFriction = 100000;
    checkForAndHandleCollisions(colliders, 1, coeffFriction, position, velocity);
    expected = glm::vec3(0,0,0);

    if (velocity == expected){
        printf("\t\t[PASSED]: Simple high friction checkAndHandleCollisions test\n");
    } else{
        printf("\t\t[FAILED]: Simple high friction checkAndHandleCollisions test\n");
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    ImplicitCollider sphere;
    sphere.center = glm::vec3(0,5,0);
    sphere.param = glm::vec3(1,1,0);
    sphere.type = SPHERE;

    ImplicitCollider colliders2[2] = {floor, sphere};

    position = glm::vec3(0,4,0);
    velocity = glm::vec3(.5,1,-1);
    coeffFriction = .5;
    checkForAndHandleCollisions(colliders2, 2, coeffFriction, position, velocity);
    expected = glm::vec3(.2764,0,-.5528);

    if (velocity == expected){
        printf("\t\t[PASSED]: Simple multiple colliders checkAndHandleCollisions test\n");
    } else{
        printf("\t\t[FAILED]: Simple multiple colliders checkAndHandleCollisions test\n");
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    position = glm::vec3(0,4,0);
    velocity = glm::vec3(.5,-1,-1);
    coeffFriction = .5;
    checkForAndHandleCollisions(colliders2, 2, coeffFriction, position, velocity);
    expected = glm::vec3(.5,-1,-1);

    if (velocity == expected){
        printf("\t\t[PASSED]: Simple bodies are separating checkAndHandleCollisions test\n");
    } else{
        printf("\t\t[FAILED]: Simple bodies are separating checkAndHandleCollisions test\n");
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    position = glm::vec3(0,100,0);
    velocity = glm::vec3(.5,-1,-1);
    coeffFriction = .5;
    checkForAndHandleCollisions(colliders2, 2, coeffFriction, position, velocity);
    expected = glm::vec3(.5,-1,-1);

    if (velocity == expected){
        printf("\t\t[PASSED]: Simple no collision checkAndHandleCollisions test\n");
    } else{
        printf("\t\t[FAILED]: Simple no collision checkAndHandleCollisions test\n");
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    printf("\tDone testing checkAndHandleCollisions\n");
    
}


//__global__ void updateVelocities(ParticleGrid::Node *nodes, float dt, ImplicitCollider* colliders,
//                                  int numColliders, WorldParams *worldParams, Grid *grid){
//    int nodeIdx = blockIdx.x*blockDim.x + threadIdx.x;
//    int gridI, gridJ, gridK;
//    gridIndexToIJK(nodeIdx, gridI, gridJ, gridK, grid);
//    ParticleGrid::Node &node = nodes[nodeIdx];
//    glm::vec3 nodePosition = glm::vec3(gridI, gridJ, gridK)*grid->h + grid->pos;

//    glm::vec3 tmpVelocity = node.velocity + dt*(node.force/node.mass);
//    checkForAndHandleCollisions(colliders, numColliders, worldParams->coeffFriction, nodePosition, tmpVelocity);
//    node.velocityChange = tmpVelocity - node.velocity;
//    node.velocity = tmpVelocity;
//}

//__global__ void updateVelocitiesTest(){
//    printf("\tTesting updateVelocities");

//    Grid grid;
//    grid.dim = glm::vec3(1,0,0);
//    grid.h = 1;

//    float dt = 1;

//    ParticleGrid::Node nodes[2];
//    //nodes[0].position = glm::vec3(0,0,0), implicitly by index
//    nodes[0].mass = 1;
//    nodes[0].force = glm::vec3(1,1,1);
//    nodes[0].velocity = glm::vec3(0,1,0);

//    //nodes[1].position = glm::vec3(1,0,0), implicitly by index
//    nodes[1].mass = 2;
//    nodes[1].force = glm::vec3(0,4,0);
//    nodes[1].velocity = glm::vec3(0,0,0);


//    ImplicitCollider sphere;
//    sphere.center = glm::vec3(1,1,0);
//    sphere.param = glm::vec3(1,0,0);
//    sphere.type = SPHERE;
//    ImplicitCollider colliders[1] = {sphere};

//    WorldParams wp;
//    wp.coeffFriction = .5;


//    updateVelocities<<<2,1>>>(nodes, dt, colliders, 1, &wp, &grid);

//    glm::vec3 node0VExpected = glm::vec3(1,2,1);
//    if (nodes[0].velocity == node0VExpected){
//        printf("\t\t[PASSED]: Simple no collision updateVelocities test\n");
//    } else{
//        printf("\t\t[FAILED]: Simple no collision updateVelocities test\n");
//        glm::vec3 expected = node0VExpected;
//        glm::vec3 velocity = nodes[0].velocity;
//        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
//    }

//    glm::vec3 node1VExpected = glm::vec3(0,0,0);
//    if (nodes[1].velocity == node0VExpected){
//        printf("\t\t[PASSED]: Simple no collision updateVelocities test\n");
//    } else{
//        printf("\t\t[FAILED]: Simple no collision updateVelocities test\n");
//        glm::vec3 expected = node1VExpected;
//        glm::vec3 velocity = nodes[1].velocity;
//        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
//    }
//    printf("\tDone testing updateVelocities");
//}

//Particle *particleData, Grid *grid, ParticleGrid::Node *nodes, WorldParams *worldParams

#define NUM_PARTICLES 2

void testGridMath(){
    printf("\nTesting grid math\n");
    testComputeSigma<<<1,1>>>();
    cudaDeviceSynchronize();
    printf("\tTesting computeCellMassVelocityAndForce()\n");
    Particle particles[NUM_PARTICLES];
    for (int i = 0; i < NUM_PARTICLES; i++){
        particles[i].mass = i+1;
        particles[i].elasticF = glm::mat3(1.0f);//Won't try more complicated values because we test sigma computation elsewhere
        particles[i].plasticF = glm::mat3(1.0f);
        particles[i].velocity = glm::vec3(i+1);
        particles[i].position = glm::vec3(i);
        particles[i].volume = i+1;
    }

    Grid grid;
    grid.dim = glm::ivec3(1,1,1);
    grid.h = 1;
    grid.pos = glm::vec3(0,0,0);

    WorldParams wp;
    wp.lambda = wp.mu = wp.xi = 1;

    ParticleGrid::Node nodes[grid.nodeCount()];

    Particle *dev_particles;
    Grid *dev_grid;
    WorldParams *dev_wp;
    ParticleGrid::Node *dev_nodes;

    checkCudaErrors(cudaMalloc((void**) &dev_particles, NUM_PARTICLES*sizeof(Particle)));
    checkCudaErrors(cudaMemcpy(dev_particles,particles,NUM_PARTICLES*sizeof(Particle),cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMalloc((void**) &dev_grid, sizeof(Grid)));
    checkCudaErrors(cudaMemcpy(dev_grid,&grid,sizeof(Grid),cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMalloc((void**) &dev_wp, sizeof(WorldParams)));
    checkCudaErrors(cudaMemcpy(dev_wp,&wp,sizeof(WorldParams),cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMalloc((void**) &dev_nodes, grid.nodeCount()*sizeof(ParticleGrid::Node)));
    checkCudaErrors(cudaMemcpy(dev_nodes,&nodes,grid.nodeCount()*sizeof(ParticleGrid::Node),cudaMemcpyHostToDevice));

    computeCellMassVelocityAndForce<<<NUM_PARTICLES, 1>>>(dev_particles, dev_grid, dev_wp, dev_nodes);

    checkCudaErrors(cudaMemcpy(nodes,dev_nodes,grid.nodeCount()*sizeof(ParticleGrid::Node),cudaMemcpyDeviceToHost));

    //I only check masses because the rest are derived from the same way mass is. The only one that is different is
    // force which I check the sigma function separately
    //These values are from the computeMasses.m file with this initial setup
    float expectedMasses[8] ={.3056, .1111, .1111, .1667, .1111, .1667, .1667, .5972};
    bool failed = false;
    for (int i =0; i < grid.nodeCount(); i++){
        int I,J,K;
        gridIndexToIJK(i, I, J, K, &grid);
        ParticleGrid::Node node = nodes[i];
        if ( std::abs(expectedMasses[i] - node.mass) > 1e-4){
            printf("\t\tActual mass (%f) didn't equal expected mass (%f) for node: (%d, %d, %d)\n", node.mass, expectedMasses[i], I,J,K);
            failed = true;
        }
        //printf("Node: ( %d, %d, %d), mass: %f\n", I,J,K, node.mass);
    }
    if (failed){
        printf("\t\t[FAILED]: Simple computeCellMassVelocityAndForce() test\n");
    }else{
        printf("\t\t[PASSED]: Simple computeCellMassVelocityAndForce() test\n");
    }


    cudaFree(dev_particles);
    cudaFree(dev_grid);
    cudaFree(dev_wp);
    cudaFree(dev_nodes);

    checkCudaErrors(cudaDeviceSynchronize());
    printf("\tDone testing computeCellMassVelocityAndForce()\n");


    testCheckForAndHandleCollisions<<<1,1>>>();
    checkCudaErrors(cudaDeviceSynchronize());


    printf("\tTesting updateVelocities\n");

    grid.dim = glm::vec3(1,0,0);
    grid.h = 1;

    float dt = 1;

    ParticleGrid::Node nodes2[2];
    //nodes[0].position = glm::vec3(0,0,0), implicitly by index
    nodes2[0].mass = 1;
    nodes2[0].force = glm::vec3(1,1,1);
    nodes2[0].velocity = glm::vec3(0,1,0);

    //nodes[1].position = glm::vec3(1,0,0), implicitly by index
    nodes2[1].mass = 2;
    nodes2[1].force = glm::vec3(0,4,0);
    nodes2[1].velocity = glm::vec3(0,0,0);


    ImplicitCollider sphere;
    sphere.center = glm::vec3(1,1,0);
    sphere.param = glm::vec3(1,0,0);
    sphere.type = SPHERE;
    ImplicitCollider colliders[1] = {sphere};

    wp.coeffFriction = .5;

    ImplicitCollider *dev_colliders;

    checkCudaErrors(cudaMalloc((void**) &dev_colliders, sizeof(ImplicitCollider)));
    checkCudaErrors(cudaMemcpy(dev_colliders,&colliders,sizeof(ImplicitCollider),cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMalloc((void**) &dev_grid, sizeof(Grid)));
    checkCudaErrors(cudaMemcpy(dev_grid,&grid,sizeof(Grid),cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMalloc((void**) &dev_wp, sizeof(WorldParams)));
    checkCudaErrors(cudaMemcpy(dev_wp,&wp,sizeof(WorldParams),cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMalloc((void**) &dev_nodes, grid.nodeCount()*sizeof(ParticleGrid::Node)));
    checkCudaErrors(cudaMemcpy(dev_nodes,&nodes2,grid.nodeCount()*sizeof(ParticleGrid::Node),cudaMemcpyHostToDevice));

    updateVelocities<<<2,1>>>(dev_nodes, dt, dev_colliders, 1, dev_wp, dev_grid);

    checkCudaErrors(cudaMemcpy(nodes2,dev_nodes,grid.nodeCount()*sizeof(ParticleGrid::Node),cudaMemcpyDeviceToHost));

    glm::vec3 node0VExpected = glm::vec3(1,2,1);
    if (nodes2[0].velocity == node0VExpected){
        printf("\t\t[PASSED]: Simple no collision updateVelocities test\n");
    } else{
        printf("\t\t[FAILED]: Simple no collision updateVelocities test\n");
        glm::vec3 expected = node0VExpected;
        glm::vec3 velocity = nodes2[0].velocity;
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    glm::vec3 node1VExpected = glm::vec3(0,0,0);
    if (nodes2[1].velocity == node1VExpected){
        printf("\t\t[PASSED]: Simple no collision updateVelocities test\n");
    } else{
        printf("\t\t[FAILED]: Simple no collision updateVelocities test\n");
        glm::vec3 expected = node1VExpected;
        glm::vec3 velocity = nodes2[1].velocity;
        printf("\t\t\tActual: (%f, %f, %f)  Expected: (%f, %f, %f)\n", velocity.x, velocity.y, velocity.z, expected.x, expected.y, expected.z);
    }

    cudaFree(dev_colliders);
    cudaFree(dev_grid);
    cudaFree(dev_wp);
    cudaFree(dev_nodes);

    printf("\tDone testing updateVelocities");

    printf("Done testing grid math\n");

}

#endif // WIL_CU
