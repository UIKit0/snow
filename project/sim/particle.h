/**************************************************************************
**
**   SNOW - CS224 BROWN UNIVERSITY
**
**   particle.h
**   Author: mliberma
**   Created: 6 Apr 2014
**
**************************************************************************/

#ifndef PARTICLE_H
#define PARTICLE_H

#include "cuda/vector.cu"
#include "cuda/matrix.cu"
#include "material.h"

#ifdef CUDA_INCLUDE
    #define DECL __host__ __device__
#else
    #define DECL
#endif

struct Particle
{
    vec3 position;
    vec3 velocity;
    float mass;
    float volume;
    mat3 elasticF;
    mat3 plasticF;
    vec3 normal;
    MaterialConstants material;
    DECL Particle()
    {
        position = vec3( 0.f, 0.f, 0.f );
        velocity = vec3( 0.f, 0.f, 0.f );
        mass = 1e-6;
        volume = 1e-9;
        elasticF = mat3( 1.f );
        plasticF = mat3( 1.f );
        normal = vec3(1,0,0);
        material = MaterialConstants();
    }
};

struct ParticleTempData
{
    mat3 sigma;
    vec3 particleGridPos;
};

#endif // PARTICLE_H
