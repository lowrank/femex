classdef QPAT < handle
    %QPAT QPAT is class for solving inverse problem in Quantitative
    %Photo-Acoustic Tomography. Instead of reconstructing traditional
    %coefficients like absorption, scattering, Gruneisen, it intends to
    %find out the invariants chi and q introduced in [1].
    
    % Numerically, the forward problem is solved by finite element method
    % (CG) on 2D unstructured triangle mesh. And the inverse problem is solved
    % by either optimization based method or direct method.
    
    % In this demo, domain is unit square [1cm x 1cm]. To be consistent, all 
    % notations follow the paper [1]. And for simplicity, we make 
    % assumptions that coefficients D, sigma, Gamma are known on boundary
    % and have constant background values.
    
    % Copyright@ Yimin Zhong, Dept. of Mathematics, University of Texas at Austin.
    
    % [1].
    
    % todo: comments for each method.
    %       manual file.
    
    properties (Access = private)
        matrix % essential matrix for convenient calls.
        loads  % load vectors for solving forward problems.
    end
    
    properties (Access = public)
        H      % cell array for measurements.
        J      % cell array for measurements.
        params % struct of parameteres chi and q.
        consts % struct of constants of background for D, sigma, Gamma, kappa.  
        coeffs % struct of coefficients of D, sigma, Gamma.
        core   % finite element solver (single threaded.)       
        mesh   % mesh quantities (total nodes, free nodes, fixed nodes).
    end
    
    methods 
        function obj = QPAT() 
            % initialization of properties. Detailed explanation refers to
            % help function.
            obj.H = {}; obj.params = struct('q', [], 'c', []);
            obj.matrix = struct('e', [], 'm', [], 's', []);
            obj.consts = struct('d', 0.01, 's', 0.2, 'g', 0.5, 'k', 1.0, 'f', 200);
            obj.coeffs = struct('d', [], 's', [], 'g', [], 't', []);         
            obj.mesh   = struct('n', 0,  'ndofs', [], 'dofs', []);
            
            obj.core   = FEM([0 0 1 0 1 1 0 1]', 1, 1.0/2/20/20, []', 3);
            
            obj.mesh.n = size(obj.core.Promoted.nodes, 2);
            obj.mesh.ndofs = unique(obj.core.Promoted.edges);
            obj.mesh.dofs  = setdiff(1:obj.mesh.n, obj.mesh.ndofs);
            
            % Edge matrix stay unchanged.
            obj.matrix.e = obj.core.assemlbc(1, obj.core.Promoted.edges);
            % Mass matrix.
            obj.matrix.m = obj.core.assema(1);
            % Stiffness matrix.
            obj.matrix.s = obj.core.assems(1);
                        
            qnodes1D = obj.core.Assembler.qnodes1D(obj.core.Promoted.nodes,...
                    obj.core.Edge.Qnodes, obj.core.Promoted.edges);

            % build load vectors and coefficients.
            sources = QPAT.get_sources(@external_sources, obj.consts.d, obj.consts.s);
            for s_id = 1:length(sources)
                cur_load = sources{s_id}(qnodes1D');
                obj.loads{s_id} =  obj.core.assemrbc(cur_load, obj.core.Promoted.edges);   
            end
            
            obj.get_coeffs(@diffusionF, @absorptionF, @GruneisenF);
            
            obj.forward_solve_pat();
            
            
        end
        
        function delete (obj)
            obj.core.delete();
        end
        
        function get_coeffs(obj, d, s, g) 
            obj.coeffs.d = d(obj.core.Promoted.nodes');
            obj.coeffs.s = s(obj.core.Promoted.nodes');
            obj.coeffs.g = g(obj.core.Promoted.nodes');
        end
        
        function forward_solve_pat(obj)
            qD     = obj.facet_mapping(obj.coeffs.d);
            qsigma = obj.facet_mapping(obj.coeffs.s);

            % assembled matrix for finite element. 
            % mass matrix + stiff matrix + edge part.
            assemb_pat = obj.core.assema(qsigma) + obj.core.assems(qD) + (1.0/obj.consts.k) * obj.matrix.e;

            tic;
            error = 0.;
            for l_id = 1:length(obj.loads)
                u = assemb_pat \ obj.loads{l_id};
                error = max(error , abs(norm(assemb_pat * u - obj.loads{l_id})) / norm(obj.loads{l_id}));
                % simple noises
                obj.H{l_id} = obj.coeffs.g .* obj.coeffs.s .* u .*(1 + 0.02*( rand(obj.mesh.n, 1) - 0.5));
            end
            t = toc;
            fprintf('\n\nestimate error of forward solver (PAT) is %2.3e, total solving time is %2.3e seconds\n\n', error, t);

        end

        
        function forward_solve_ot(obj)
            qD     = obj.facet_mapping(obj.coeffs.d);
            qsigma = obj.facet_mapping(obj.coeffs.s);

            omega = obj.consts.f * 2 * pi * 10^6 / (3 * 10^8);
            
            % assembled matrix for finite element. 
            % mass matrix + stiff matrix + edge part.
            assemb_ot = ...
                obj.core.assema(qsigma) + obj.core.assems(qD) + ...
                (1.0/obj.consts.k) * obj.matrix.e + sqrt(-1) * omega * obj.matrix.m;
            
            % loads are point sources on boundary.
            tmp = 10^4 * eye(obj.mesh.n);
            ps = tmp(:, obj.mesh.ndofs);
            obj.J = cell(length(obj.mesh.ndofs), 1);
            
            tic;
           
            v = assemb_ot \ ps;
            error = norm(assemb_ot * v - ps)/norm(v);
           
 
            for l_id = 1:length(obj.mesh.ndofs)
                obj.J{l_id} =  v(obj.mesh.ndofs, l_id) .*(1 + 0.00*( rand(size(obj.mesh.ndofs, 1), 1) - 0.5));
            end
            
            t = toc;
            fprintf('\n\nestimate error of forward solver (OT) is %2.3e, total solving time is %2.3e seconds\n\n', error, t);
            
        end
       
        function [interpolate] = facet_mapping(obj, func)
            % allocate memory
            numq = size(obj.core.Facet.Ref', 1);
            interpolate = zeros(numq, size(obj.core.Promoted.elems, 2));
            for i = 1: size(obj.core.Promoted.elems, 2)
                interpolate(:, i) = obj.core.Facet.Ref' * func(obj.core.Promoted.elems(:, i));
            end
        end
        
        function [interpolate] = edge_mapping(obj, func)
            numq = size(obj.core.Edge.Ref', 1);
            interpolate = zeros(numq, size(obj.core.Promoted.edges, 2));
            for i = 1: size(obj.core.Promoted.edges, 2)
                interpolate(:, i) = obj.core.Edge.Ref' * func(obj.core.Promoted.edges(:, i));
            end
        end
        
        function [ret, hist] = backward_solve_chi(obj, x0)
            % this function solves chi with some regularization first.
            
            % set some shortcuts for variables.
            ndofs = obj.mesh.ndofs;
            n     = obj.mesh.n;
            d     = obj.coeffs.d;
            s     = obj.coeffs.s;
            g     = obj.coeffs.g;
            
            % preallocation of chi.
            obj.params.c = zeros(n, 1);
            
            % prescribe boundary condition for chi (piecewise smooth).
            obj.params.c(ndofs) = d(ndofs) ./ (s(ndofs).^2) ./ (g(ndofs).^2);
            assert(all(obj.params.c(ndofs) == obj.consts.d / obj.consts.s^2 / obj.consts.g^2));
            
            % set shortcut for chi parameter.
            
            if (nargin < 2)
                % use background value.
                bg = obj.consts.d / obj.consts.s^2 / obj.consts.g^2;
                x0 = bg * ones(n, 1); 
            end
     
            
            opts    = struct( 'factr', 1e-20, 'pgtol', 1e-12, 'm', 400, 'x0', x0, 'maxIts', 2e2, 'maxTotalIts', 1e5);
            opts.printEvery = 1;
            tic;
            [ret, ~, hist] = lbfgsb_c(@obj.ogc, zeros(n, 1), inf * ones(n, 1), opts);
            obj.params.c = ret;
            t = toc;
            fprintf('\n\ntotal time in L-BFGS is %2.3e seconds, using %2.3e iterations.\n\n', t, hist.iterations);
        
        end
      
        function [ret, hist] = backward_solve_q(obj, x0)
            % this function solves q with some regularization first.
            
            % set some shortcuts for variables.
            ndofs = obj.mesh.ndofs;
            n     = obj.mesh.n;
            d     = obj.coeffs.d;
            s     = obj.coeffs.s;
            g     = obj.coeffs.g;
            
            % preallocation of q.
            obj.params.q = zeros(n, 1);
            
            % prescribe boundary condition for q (piecewise smooth).
            obj.params.q(ndofs) = d(ndofs) ./ s(ndofs) ;
            assert(all(obj.params.q(ndofs) == obj.consts.d / obj.consts.s));
            
            % set shortcut for chi parameter.
            
            if (nargin < 2)
                % use background value.
                bg = obj.consts.s ./ obj.consts.d;
                x0 = bg * ones(n, 1); 
            end
     
            
            opts    = struct( 'factr', 1e-20, 'pgtol', 1e-12, 'm', 400, 'x0', x0, 'maxIts', 2e2, 'maxTotalIts', 1e5);
            opts.printEvery = 1;
            tic;
            [ret, ~, hist] = lbfgsb_c(@obj.ogq, zeros(n, 1), inf * ones(n, 1), opts);
            obj.params.q = ret;
            t = toc;
            fprintf('\n\ntotal time in L-BFGS is %2.3e seconds, using %2.3e iterations.\n\n', t, hist.iterations);
        
        end
        
        function [ret, hist] = backward_solve_t(obj, x0)
            % this function solves t with some regularization first.
            
            % set some shortcuts for variables.
            ndofs = obj.mesh.ndofs;
            n     = obj.mesh.n;
            d     = obj.coeffs.d;
            s     = obj.coeffs.s;
            g     = obj.coeffs.g;
            
            % preallocation of q.
            obj.params.t = zeros(n, 1);
            
            % prescribe boundary condition for q (piecewise smooth).
            obj.params.t(ndofs) = 1 ./ d(ndofs) ;
            assert(all(obj.params.t(ndofs) == 1 / obj.consts.d));
            
            % set shortcut for chi parameter.
            
            if (nargin < 2)
                % use background value.
                bg = 1 ./ obj.consts.d;
                x0 = bg * ones(n, 1); 
            end
     
            
            opts    = struct( 'factr', 1e-20, 'pgtol', 1e-20, 'm', 400, 'x0', x0, 'maxIts', 2e4, 'maxTotalIts', 1e5);
            opts.printEvery = 1;
            tic;
            [ret, ~, hist] = lbfgsb_c(@obj.ogt, zeros(n, 1), inf * ones(n, 1), opts);
            obj.params.t = ret;
            t = toc;
            fprintf('\n\ntotal time in L-BFGS is %2.3e seconds, using %2.3e iterations.\n\n', t, hist.iterations);
                   
        end
       
        function [f, g] = ogc(obj, c)
            % shortcuts for variables.
            ndofs = obj.mesh.ndofs;
            dofs  = obj.mesh.dofs;
            n     = obj.mesh.n;
            f     = 0;
            g     = zeros(n, 1);
            alpha = 1e-6 * n; % regularization parameter is normalized by n.
            
            % should use multiple data, may give better convergence rate.
            m = length(obj.H);
            
            for id = 1:m
                data = obj.H{mod(id, m) + 1} ./ obj.H{id};

                scat = c .* (obj.H{id}.^2);

                qsca = obj.facet_mapping(scat);
                mats = obj.core.assems(qsca);

                u = zeros(n, 1);
                v = zeros(n, 1);
                u(ndofs) = data(ndofs);

                tmp = mats * u;
                u(dofs) = -mats(dofs, dofs) \ tmp(dofs);

                f = f + 0.5 * (u - data)'*(u - data);
                tmp = u - data;
                v(dofs) = mats(dofs, dofs) \ tmp(dofs);

                g = g - obj.core.assemnode(u, v,  (obj.H{id}.^2), zeros(n, 1));
            end
            
            f = f + 0.5 * alpha * (c' * obj.matrix.s * c);
            g = g + alpha * obj.matrix.s * c;  

            g(ndofs) = 0.;
            
        end
             
        function [f, g] = ogq(obj, q)
            % shortcuts for variables.
            ndofs = obj.mesh.ndofs;
            dofs  = obj.mesh.dofs;
            n     = obj.mesh.n;
            f     = 0;
            g     = zeros(n, 1);
            alpha = 5e-10 * n; % regularization parameter is normalized by n.
            
            % should use multiple data, may give better convergence rate.
            m = length(obj.H);
            
            % unchanged coefficients during loop.
            absp = q;
            qabs = obj.facet_mapping(absp);
            mats = obj.matrix.s + obj.core.assema(qabs);
            
            for id = 1 : m
                data = sqrt(obj.params.c) .* obj.H{id};
    
                u = zeros(n, 1);
                v = zeros(n, 1);
                u(ndofs) = data(ndofs);

                tmp = mats * u;
                u(dofs) = -mats(dofs, dofs) \ tmp(dofs);

                f = f + 0.5 * (u - data)'*(u - data) ;
                tmp = u - data;
                v(dofs) = mats(dofs, dofs) \ tmp(dofs);

                g = g - obj.core.assemnode(u, v, zeros(n, 1), ones(n,1));
                     
            end
            
            
            f = f + 0.5 * alpha * (q' * obj.matrix.s * q);
            g = g + alpha * obj.matrix.s * q;  

            
            g(ndofs) = 0.;

        end

        function [f, g] = ogt(obj, t)            
            % shortcuts for variables.
            ndofs = obj.mesh.ndofs;
            dofs  = obj.mesh.dofs;
            n     = obj.mesh.n;
            f     = 0;
            g     = zeros(n, 1);
            alpha = 1e-5 * size(ndofs, 1); % regularization parameter is normalized by n.
            
            % modularized frequency for OT.
            omega = obj.consts.f * 2 * pi * 10^6 / (3 * 10^8);
            
            % since now all things are in complex form. We use suffix
            % 'real' and 'imag' to recognize them. 
            % Caution: all assembly routines only perform on real numbers.
            absp_real = obj.params.q;
            qabs_real = obj.facet_mapping(absp_real);
            
            absp_imag = t;
            qabs_imag = obj.facet_mapping(absp_imag);
            mats = obj.matrix.s + obj.core.assema(qabs_real) + ...
                (1.0/obj.consts.k/obj.consts.d) * obj.matrix.e + sqrt(-1) * omega * obj.core.assema(qabs_imag); 
            
            m = length(obj.J);
                        
            tmp = (1/sqrt(obj.consts.d)) * 10^4 *  eye(obj.mesh.n);
            ps = tmp(:, obj.mesh.ndofs);
            
            % measured data is now complex.
            v = mats \ ps;

            for i = 1:m
                data = v(ndofs, i);
                mismatch = data - sqrt(obj.consts.d) * obj.J{i};
                
                % mismatch is complex.
                f = f + 0.5 * (mismatch' * mismatch);
                
                load = zeros(n, 1);
                load(ndofs) = mismatch;
                phi = mats\conj(load);
                
                rp = real(phi);  cp = imag(phi); 
                rd = real(v(:, i)); cd = imag(v(:, i)); 
                
                g = g + ...
                    omega * obj.core.assemnode(rp, cd, zeros(n,1), ones(n,1) ) + ...
                    omega * obj.core.assemnode(cp, rd, zeros(n,1), ones(n,1) );
               
            end
            
            
            f = f + 0.5 * alpha * (t' * obj.matrix.s * t);
            g = g + alpha * obj.matrix.s * t;
            
            
            g(ndofs) = 0;

        end
        
        function visualize(obj, var)
            figure;
            trisurf(obj.core.TriMesh', ...
                obj.core.Promoted.nodes(1,:)', ...
                obj.core.Promoted.nodes(2,:)', ...
                var, 'EdgeColor', 'none' ); shading interp; colormap jet; colorbar;view(2);
        end
    end
    
    methods (Static)
        
        function sources = get_sources(funcs_handler, d, s)
            funcs = funcs_handler(d, s);
            n = length(funcs);
            sources = cell(n , 1);
            for f_id = 1 : n
                sources{f_id} = funcs{f_id};
            end
        end 

    end
    
end

