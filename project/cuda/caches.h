/**************************************************************************
**
**   SNOW - CS224 BROWN UNIVERSITY
**
**   caches.h
**   Authors: evjang, mliberma, taparson, wyegelwe
**   Created: 28 Apr 2014
**
**************************************************************************/

#ifndef CACHES_H
#define CACHES_H

struct vec3;

// Cache for data used by Conjugate Residual Method
struct CRCache
{
    vec3 *r;
    vec3 *s;
    vec3 *p;
    vec3 *q;
    vec3 *v;
};

#endif // CACHES_H
