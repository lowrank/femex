/*
 * Radfmmk.cpp
 *
 *  Created on: Oct 27, 2015
 *      Author: lurker
 */

#include "BBFMM2D.hpp"

#include <mexplus.h>
#include "utils.h"

using namespace std;
using namespace mexplus;

static std::vector<double> X {
        -0.90617984593866396370032134655048,
        -0.53846931010568310771446931539685,
        0,
        0.53846931010568310771446931539685,
        0.90617984593866396370032134655048

};
static std::vector<double> W {
        0.23692688505618908489935847683228,
        0.47862867049936647090291330641776,
        0.56888888888888888888888888888889,
        0.47862867049936647090291330641776,
        0.23692688505618908489935847683228
};
inline double distance(double x0, double y0, double x1, double y1) noexcept {
    return sqrt((x0 - x1) * (x0 - x1) + (y0 - y1) * (y0 - y1));
}

inline double integral_corner(double sigma_t, double length) {
    double ret = 0.;
    double mid = (sqrt(2) + 1.0) * length/4.0;
    double rad = (sqrt(2) - 1.0) * length/4.0;
    for (int i = 0; i < X.size(); ++i) {
        double val = (mid + rad * X[i]);
        ret += exp(-sigma_t * val) * (M_PI/2.0 - 2 * acos(length/2.0/val)) * W[i];
    }
    ret *= 4.0 * rad;
    return ret;
}

class kernel_Radfmm: public kernel_Base {
public:
	// involves some grid data to locate information
	unsigned long side;
	double start_x;
	double start_y;
	double *mu_t;

	double integral_helper( double x0, double y0, double x1, double y1) noexcept {
	    return distance(x0, y0, x1, y1) * this->getAttribute((x0 + x1)/2 , (y0 + y1)/2);
	}

	double integral(double x0, double y0, double x1, double y1) noexcept {
	    if (distance(x0, y0, x1, y1) < 1.0/side) return integral_helper(x0, y0, x1, y1);
	    else {
	        auto xm = (x0 + x1)/2;
	        auto ym = (y0 + y1)/2;
	        return integral( x0, y0, xm, ym) +
	               integral( xm, ym, x1, y1);
	    }
	}
	double getAttribute(double x, double y);
    virtual double kernel_Func(Point r0, Point r1);
};
double kernel_Radfmm::kernel_Func(Point r0, Point r1){
    double rSquare	= distance(r0.x, r0.y, r1.x, r1.y) ;
    if (rSquare == 0){
    	return (1.0 - exp(- this->getAttribute(r0.x, r0.y)/side/2.0))/ this->getAttribute(r0.x, r0.y) +
    			integral_corner(this->getAttribute(r0.x, r0.y), 1.0/side)/(2*M_PI);
    }
    else{
        return exp(-this->integral(r0.x, r0.y, r1.x, r1.y))/rSquare/(2*M_PI)/side/side;
    }
}

double kernel_Radfmm::getAttribute(double x, double y) {
    auto col = (unsigned long)((x - start_x) * side);
    auto row = (unsigned long)((y - start_y) * side);

    return mu_t[row * side + col];
}

template class mexplus::Session<kernel_Radfmm>;

namespace {

MEX_DEFINE(new)(int nlhs, mxArray* plhs[], int nrhs, const mxArray* prhs[]){
	InputArguments input(nrhs, prhs, 0);
	OutputArguments output(nlhs, plhs, 1);
	output.set(0, Session<kernel_Radfmm>::create(new kernel_Radfmm()));

}

MEX_DEFINE(delete) (int nlhs, mxArray* plhs[], int nrhs, const mxArray* prhs[]) {
	InputArguments input(nrhs, prhs, 1);
	OutputArguments output(nlhs, plhs, 0);
	Session<kernel_Radfmm>::destroy(input.get(0));
}

MEX_DEFINE(calc) (int nlhs, mxArray* plhs[], int nrhs, const mxArray* prhs[]) {
	InputArguments input(nrhs, prhs, 5);
	OutputArguments output(nlhs, plhs, 1);

	auto root = Session<H2_2D_Tree>::get(input.get(1));
	auto kern = Session<kernel_Radfmm>::get(input.get(0));

	auto N_p = mxGetPr(prhs[2]);
	auto m_p = mxGetPr(prhs[3]);
	auto mu_t_ptr = mxGetPr(prhs[4]);

	plhs[0] = mxCreateNumericMatrix((unsigned long)*N_p, (unsigned)*m_p,mxDOUBLE_CLASS, mxREAL);

	kern->mu_t = mu_t_ptr;
	kern->side = (unsigned long)(sqrt(*N_p));
	kern->start_x = 0.;
	kern->start_y = 0.;
	kern->calculate_Potential(*root, mxGetPr(plhs[0]));

}

MEX_DEFINE(calc_cache) (int nlhs, mxArray* plhs[], int nrhs, const mxArray* prhs[]) {
	InputArguments input(nrhs, prhs, 7);
	OutputArguments output(nlhs, plhs, 1);

	auto kern = Session<kernel_Radfmm>::get(input.get(0));

	auto ncheb_ptr = mxGetPr(prhs[1]);
	auto charges_ptr = mxGetPr(prhs[2]);

	auto location_ptr = mxGetPr(prhs[3]);
	auto numberoflocation = mxGetN(prhs[3]);

	auto N_ptr = mxGetPr(prhs[4]);
	auto m_ptr = mxGetPr(prhs[5]);

	auto mu_t_ptr = mxGetPr(prhs[6]);

	vector<Point> location;

	location.resize(numberoflocation);

	for(size_t i = 0; i < numberoflocation; i++) {
		location[i].x = location_ptr[2 * i];
		location[i].y = location_ptr[2 * i + 1];
	}

	auto root = new H2_2D_Tree(
				(unsigned short)*ncheb_ptr,
				charges_ptr,
				location,
				(unsigned long)*N_ptr,
				(unsigned)*m_ptr);

	plhs[0] = mxCreateNumericMatrix((unsigned long)*N_ptr, (unsigned)*m_ptr,mxDOUBLE_CLASS, mxREAL);


	kern->mu_t = mu_t_ptr;
	kern->side = (unsigned long)(sqrt(*N_ptr));
	kern->start_x = 0.;
	kern->start_y = 0.;
	kern->calculate_Potential_cache(*root, mxGetPr(plhs[0]));

	delete root;

}

MEX_DEFINE(calc_fast) (int nlhs, mxArray* plhs[], int nrhs, const mxArray* prhs[]) {
	InputArguments input(nrhs, prhs, 7);
	OutputArguments output(nlhs, plhs, 1);

	auto kern = Session<kernel_Radfmm>::get(input.get(0));

	auto ncheb_ptr = mxGetPr(prhs[1]);
	auto charges_ptr = mxGetPr(prhs[2]);

	auto location_ptr = mxGetPr(prhs[3]);
	auto numberoflocation = mxGetN(prhs[3]);

	auto N_ptr = mxGetPr(prhs[4]);
	auto m_ptr = mxGetPr(prhs[5]);
	auto mu_t_ptr = mxGetPr(prhs[6]);

	vector<Point> location;

	location.resize(numberoflocation);

	for(size_t i = 0; i < numberoflocation; i++) {
		location[i].x = location_ptr[2 * i];
		location[i].y = location_ptr[2 * i + 1];
	}

	auto root = new H2_2D_Tree(
				(unsigned short)*ncheb_ptr,
				charges_ptr,
				location,
				(unsigned long)*N_ptr,
				(unsigned)*m_ptr);



	plhs[0] = mxCreateNumericMatrix((unsigned long)*N_ptr, (unsigned)*m_ptr,mxDOUBLE_CLASS, mxREAL);


	kern->mu_t = mu_t_ptr;
	kern->side = (unsigned long)(sqrt(*N_ptr));
	kern->start_x = 0.;
	kern->start_y = 0.;
	kern->calculate_Potential_fast(*root, mxGetPr(plhs[0]));

	delete root;

}

MEX_DEFINE(disp) (int nlhs, mxArray* plhs[], int nrhs, const mxArray* prhs[]) {
	InputArguments input(nrhs, prhs, 1);
	OutputArguments output(nlhs, plhs, 0);

	auto kern = Session<kernel_Radfmm>::get(input.get(0));

	std::cout << "Storage of Matrices : " << kern->cache.size() << std::endl;

	size_t sum = 0;
	for (auto& m : kern->cache) {
		sum += m.size();
	}

	std::cout << "Memory allocated : " << sum * 8 / 1024 / 1024 << " MB" << std::endl;
}
}
MEX_DISPATCH
